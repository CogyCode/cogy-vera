#!/bin/bash
# Installs Vera on an NVIDIA Jetson AGX Xavier (JetPack 5). Settings:
# config/settings.env. Run join-network.sh first. Safe to re-run: each step is
# skipped when it is already done.
#
#   1. Checks: Jetson, CUDA, private network, GPU memory
#   2. llama.cpp built for CUDA (pinned commit)
#   3. Model (pinned revision, SHA-256 checked)
#   4. Service account, Vera's code and configuration
#   5. systemd services: firewall, llama-server, Vera
#   6. Self-test: /health, POST /verify, OpenAI passthrough
#
#   sudo ./install.sh --allow-from <cogyserver-address>
#
# --allow-from is the only address admitted to Vera's port. A re-run can leave
# it out and keeps the one in the installed firewall rule.
set -euo pipefail
REPO_DIR=$(dirname "$(readlink -f "$0")")
. "$REPO_DIR/config/settings.env"

step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf '\nINSTALL FAILED: %s\n' "$*" >&2; exit 1; }

ALLOW_FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --allow-from) ALLOW_FROM=${2:-}; shift 2 || die "--allow-from needs an address" ;;
    *) die "unknown option: $1" ;;
  esac
done
[ "$(id -u)" -eq 0 ] || die "run with sudo: sudo $0 --allow-from <cogyserver-address>"
FIREWALL_UNIT="/etc/systemd/system/$FIREWALL_SERVICE_NAME.service"
if [ -z "$ALLOW_FROM" ] && [ -f "$FIREWALL_UNIT" ]; then
  ALLOW_FROM=$(sed -n 's/^ExecStart=.* ! -s \([^ ]*\) .*/\1/p' "$FIREWALL_UNIT")
fi
[ -n "$ALLOW_FROM" ] || die "CogyServer's address is required: sudo $0 --allow-from <cogyserver-address>"
[[ "$ALLOW_FROM" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "not an IPv4 address: $ALLOW_FROM"
mkdir -p "$LOG_DIR" "$PREFIX" "$DATA_DIR"
exec > >(tee "$LOG_DIR/install.log") 2>&1

# --- 1. Checks ------------------------------------------------------------------
step "Checks"
grep -qa "NVIDIA\|Jetson" /proc/device-tree/model /etc/nv_tegra_release 2>/dev/null || die "this is not a Jetson"
[ -x "$NVCC" ] || die "no CUDA compiler at $NVCC; install CUDA with JetPack (nvidia-jetpack)"
PRIVATE_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
[ -n "$PRIVATE_IP" ] || die "not on CogyServer's private network; run join-network.sh first"
info "Private address: $PRIVATE_IP"

systemctl stop "$SERVICE_NAME" "$MODEL_SERVICE_NAME" 2>/dev/null || true
for svc in $CONFLICTING_SERVICES; do
  if systemctl is-active -q "$svc"; then
    die "$svc is running and holds GPU memory; stop it first: sudo systemctl disable --now $svc"
  fi
  if systemctl is-enabled -q "$svc" 2>/dev/null; then
    info "WARNING: $svc is stopped but enabled. It will start at the next boot and"
    info "         compete for GPU memory. To prevent that: sudo systemctl disable $svc"
  fi
done
available=$(awk '/MemAvailable/ {print int($2 / 1024)}' /proc/meminfo)
[ "$available" -ge "$REQUIRED_MEMORY_MB" ] || die "$available MB of memory available; the model needs $REQUIRED_MEMORY_MB MB"
info "Memory available: $available MB"

missing=""
for pkg in git curl build-essential python3-venv; do
  dpkg -s "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
done
if [ -n "$missing" ]; then
  info "Installing:$missing"
  apt-get update -qq
  # shellcheck disable=SC2086
  apt-get install -y -qq $missing
fi

# --- 2. llama.cpp -----------------------------------------------------------------
step "llama.cpp ${LLAMA_COMMIT:0:7} for CUDA"
SRC="$DATA_DIR/src/llama.cpp"
BINARY="$SRC/build/bin/llama-server"
if [ -x "$PREFIX/llama/bin/llama-server" ] && [ "$(cat "$PREFIX/llama/COMMIT" 2>/dev/null)" = "$LLAMA_COMMIT" ]; then
  info "Already installed"
else
  # Source and tools may come from an earlier run by another user.
  chown -R root:root "$DATA_DIR/src" "$DATA_DIR/tools" 2>/dev/null || true
  mkdir -p "$DATA_DIR/src"
  [ -d "$SRC/.git" ] || git init -q "$SRC"
  git -C "$SRC" remote add origin "$LLAMA_REPO" 2>/dev/null || true
  if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" != "$LLAMA_COMMIT" ] || [ -n "$(git -C "$SRC" status --porcelain --ignore-submodules -- . ':!build')" ]; then
    git -C "$SRC" fetch -q --depth 1 origin "$LLAMA_COMMIT"
    git -C "$SRC" checkout -q --force FETCH_HEAD
    rm -rf "$SRC/build"
  fi
  if [ ! -x "$BINARY" ]; then
    if ! "$DATA_DIR/tools/bin/cmake" --version 2>/dev/null | grep -q "$CMAKE_VERSION"; then
      python3 -m venv "$DATA_DIR/tools"
      req=$(mktemp)
      printf 'cmake==%s --hash=sha256:%s\n' "$CMAKE_VERSION" "$CMAKE_SHA256" > "$req"
      "$DATA_DIR/tools/bin/pip" install -q --require-hashes --only-binary :all: -r "$req"
      rm -f "$req"
    fi
    info "Building (about 25 minutes)..."
    PATH="$(dirname "$NVCC"):$PATH" CUDACXX="$NVCC" "$DATA_DIR/tools/bin/cmake" -S "$SRC" -B "$SRC/build" \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
      -DGGML_NATIVE=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_MTMD=OFF \
      -DLLAMA_BUILD_UI=OFF -DLLAMA_CURL=OFF > "$LOG_DIR/build.log" 2>&1 || die "cmake failed; see $LOG_DIR/build.log"
    PATH="$(dirname "$NVCC"):$PATH" "$DATA_DIR/tools/bin/cmake" --build "$SRC/build" --target llama-server -j"$(nproc)" \
      >> "$LOG_DIR/build.log" 2>&1 || die "build failed; see $LOG_DIR/build.log"
  fi
  mkdir -p "$PREFIX/llama/bin"
  install -m 755 "$BINARY" "$PREFIX/llama/bin/llama-server"
  echo "$LLAMA_COMMIT" > "$PREFIX/llama/COMMIT"
fi
info "$("$PREFIX/llama/bin/llama-server" --version 2>&1 | grep -m1 version)"

# --- 3. Model ---------------------------------------------------------------------
step "Model $MODEL_ID"
MODELS="$DATA_DIR/models"
mkdir -p "$MODELS"
MODEL_PATH="$MODELS/$MODEL_FILE"
if [ "$(cat "$MODEL_PATH.ok" 2>/dev/null)" = "$MODEL_SHA256" ] && [ -f "$MODEL_PATH" ]; then
  info "Already downloaded"
else
  if [ ! -f "$MODEL_PATH" ]; then
    info "Downloading $MODEL_FILE (about 19 GB)"
    curl -fL -C - --retry 20 --retry-delay 10 -sS -o "$MODEL_PATH.part" \
      "https://huggingface.co/$MODEL_REPO/resolve/$MODEL_REVISION/$MODEL_FILE"
    mv "$MODEL_PATH.part" "$MODEL_PATH"
  fi
  got=$(sha256sum "$MODEL_PATH" | cut -d' ' -f1)
  if [ "$got" != "$MODEL_SHA256" ]; then
    rm -f "$MODEL_PATH"
    die "SHA-256 mismatch for $MODEL_FILE: got $got"
  fi
  echo "$MODEL_SHA256" > "$MODEL_PATH.ok"
  info "SHA-256 OK"
fi
# Only the configured model is kept.
find "$MODELS" -maxdepth 1 -type f ! -name "$MODEL_FILE" ! -name "$MODEL_FILE.ok" -delete
chown -R root:root "$MODELS"
chmod -R a+rX "$DATA_DIR/models"
chmod a+x "$DATA_DIR"

# --- 4. Account, code and configuration -----------------------------------------
step "Vera's code in $PREFIX"
id "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
usermod -aG video,render "$SERVICE_USER"
chown -R "$SERVICE_USER:$SERVICE_USER" "$LOG_DIR"
mkdir -p "$PREFIX/vera"
rm -rf "$PREFIX/modelserver"  # from earlier versions of this build
install -m 644 "$REPO_DIR/vera/vera.py" "$REPO_DIR/config/review-prompt.txt" "$REPO_DIR/config/verdict.schema.json" "$PREFIX/vera/"

write_json() { # path, then key=value pairs; a value starting with : is a JSON literal
  python3 - "$@" <<'PY'
import json, sys
values = {}
for pair in sys.argv[2:]:
    key, value = pair.split("=", 1)
    values[key] = json.loads(value[1:]) if value.startswith(":") else value
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(values, f, indent=2)
PY
}
write_json "$PREFIX/vera/vera.json" \
  bind="$PRIVATE_IP" port=":$PORT" upstream="http://127.0.0.1:$MODEL_PORT" model="$MODEL_ID" \
  prompt_file="$PREFIX/vera/review-prompt.txt" schema_file="$PREFIX/vera/verdict.schema.json" \
  max_tokens=":$MAX_TOKENS" retries=":1" timeout=":$TIMEOUT" log_file="$LOG_DIR/vera.log"
info "Installed"

# --- 5. Services ------------------------------------------------------------------
step "systemd services"
for name in "$FIREWALL_SERVICE_NAME:cogy-vera-firewall" "$MODEL_SERVICE_NAME:cogy-vera-model" "$SERVICE_NAME:cogy-vera"; do
  sed -e "s|@PREFIX@|$PREFIX|g; s|@DATA_DIR@|$DATA_DIR|g; s|@LOG_DIR@|$LOG_DIR|g" \
      -e "s|@SERVICE_USER@|$SERVICE_USER|g; s|@PORT@|$PORT|g; s|@ALLOW_FROM@|$ALLOW_FROM|g" \
      -e "s|@MODEL_SERVICE_NAME@|$MODEL_SERVICE_NAME|g; s|@FIREWALL_SERVICE_NAME@|$FIREWALL_SERVICE_NAME|g" \
      -e "s|@MODEL_PATH@|$MODEL_PATH|g; s|@MODEL_ID@|$MODEL_ID|g; s|@MODEL_PORT@|$MODEL_PORT|g" \
      -e "s|@CTX_SIZE@|$((CONTEXT * PARALLEL))|g; s|@PARALLEL@|$PARALLEL|g; s|@GPU_LAYERS@|$GPU_LAYERS|g" \
      -e "s|@BATCH@|$BATCH|g; s|@UBATCH@|$UBATCH|g; s|@CACHE_RAM@|$CACHE_RAM|g" \
      "$REPO_DIR/config/${name#*:}.service" > "/etc/systemd/system/${name%%:*}.service"
done
systemctl stop "$FIREWALL_SERVICE_NAME" 2>/dev/null || true
systemctl daemon-reload
systemctl enable -q "$FIREWALL_SERVICE_NAME" "$MODEL_SERVICE_NAME" "$SERVICE_NAME"
systemctl start "$FIREWALL_SERVICE_NAME"
iptables -w -t raw -C PREROUTING -p tcp --dport "$PORT" ! -i lo ! -s "$ALLOW_FROM" -j DROP || die "firewall rule is not in place"
info "Firewall: port $PORT from $ALLOW_FROM only"
systemctl start "$MODEL_SERVICE_NAME" "$SERVICE_NAME"
info "Started"

# --- 6. Self-test -----------------------------------------------------------------
step "Self-test"
BASE="http://$PRIVATE_IP:$PORT"
deadline=$((SECONDS + 900))
until curl -fsS -m 5 "$BASE/health" 2>/dev/null | grep -q '"status": "ready"'; do
  [ "$SECONDS" -lt "$deadline" ] || die "not ready within 15 minutes; see journalctl -u $MODEL_SERVICE_NAME and $LOG_DIR/vera.log"
  sleep 5
done
info "Model loaded, /health ready"
python3 "$REPO_DIR/scripts/selftest.py" "$BASE" "$MODEL_ID" || die "self-test failed; see $LOG_DIR"

printf '\nVera is installed.\n'
printf '  Verify: POST %s/verify   {"plan": "...", "diff": "..."}\n' "$BASE"
printf '  Health: GET  %s/health\n' "$BASE"
printf '  OpenAI: POST %s/v1/chat/completions, GET %s/v1/models\n' "$BASE" "$BASE"
printf '  Model:  %s  (context %s)\n' "$MODEL_ID" "$CONTEXT"
printf '  Logs:   %s\n' "$LOG_DIR"
