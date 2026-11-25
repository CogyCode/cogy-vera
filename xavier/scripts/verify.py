#!/usr/bin/env python3
"""Checks that the installed server meets its requirements.

    - Services: running, start at boot, restart on failure, start in order
    - Network: Vera on the private address only, llama-server on 127.0.0.1 only
    - Firewall: port open to CogyServer only
    - API: /health, /verify, models, chat, thinking off
    - Parallel: 2 requests run at the same time
    - Context: a prompt just under the limit is served, one just over is refused
    - GPU: generation loads the GPU
    - With --test-restart: kills the processes and waits for them to come back

    sudo python3 verify.py [--test-restart] [--skip-context]

Without sudo, the firewall and restart checks cannot run and are reported FAIL.
"""

import argparse
import random
import re
import subprocess
import sys
import threading
import time

from common import call, default_base_url, settings

S = settings()
failures = 0
WORDS = "plan step verify check order task resource budget risk owner deadline input output state goal".split()


def report(name, ok, detail=""):
    global failures
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}".rstrip())
    failures += 0 if ok else 1


def run(*cmd):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    return p.returncode, p.stdout.strip()


def show(service, prop):
    return run("systemctl", "show", service, "-p", prop, "--value")[1]


def text(n):
    return " ".join(random.choice(WORDS) for _ in range(n))


def main_pid(service):
    return show(service, "MainPID")


def wait_ready(base, seconds=900):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        time.sleep(3)
        try:
            if call(base, "GET", "/health", timeout=5)[1].get("status") == "ready":
                return True
        except (OSError, AttributeError):
            pass
    return False


def main():
    ap = argparse.ArgumentParser(description="Checks the installed server")
    ap.add_argument("--test-restart", action="store_true")
    ap.add_argument("--skip-context", action="store_true")
    args = ap.parse_args()

    base = default_base_url()
    ip = base.split("//")[1].split(":")[0]
    port, model_port = S["PORT"], S["MODEL_PORT"]
    context, model = int(S["CONTEXT"]), S["MODEL_ID"]
    vera, model_svc, firewall = S["SERVICE_NAME"], S["MODEL_SERVICE_NAME"], S["FIREWALL_SERVICE_NAME"]
    report("Private address", bool(ip), ip)

    # --- Services -------------------------------------------------------------
    for svc in (firewall, model_svc, vera):
        report(f"{svc} active", show(svc, "ActiveState") == "active", show(svc, "SubState"))
        report(f"{svc} starts at boot", show(svc, "UnitFileState") == "enabled", show(svc, "UnitFileState"))
    for svc in (model_svc, vera):
        report(f"{svc} restarts on failure", show(svc, "Restart") == "always", show(svc, "Restart"))
    after = show(vera, "After")
    report(f"{vera} starts after llama-server, firewall and Tailscale",
           all(f"{s}.service" in after for s in (model_svc, firewall, "tailscaled")))
    report("Tailscale starts at boot", show("tailscaled", "UnitFileState") == "enabled")
    for svc in S["CONFLICTING_SERVICES"].split():
        state = show(svc, "UnitFileState")
        report(f"{svc} will not start at boot and compete for GPU memory", state != "enabled", state or "not installed")

    # --- Network ---------------------------------------------------------------
    listeners = run("ss", "-ltnH")[1]

    def addresses(p):
        return sorted(set(m.group(1) for m in re.finditer(r"(\S+):" + p + r"\s", listeners)))
    report("Vera listens on the private address only", addresses(port) == [ip], ", ".join(addresses(port)))
    report("llama-server listens on 127.0.0.1 only", addresses(model_port) == ["127.0.0.1"], ", ".join(addresses(model_port)))

    # --- Firewall --------------------------------------------------------------
    # install.sh keeps CogyServer's address in the installed unit, not in the repo.
    with open(f"/etc/systemd/system/{firewall}.service", encoding="utf-8") as f:
        allow_from = re.search(r"! -s (\S+)", f.read()).group(1)
    rule = ["iptables", "-w", "-t", "raw", "-C", "PREROUTING", "-p", "tcp", "--dport", port,
            "!", "-i", "lo", "!", "-s", allow_from, "-j", "DROP"]
    code, out = run(*rule)
    report(f"Firewall drops port {port} from all but {allow_from}", code == 0, out)
    code, out = run("iptables", "-w", "-t", "raw", "-S", "PREROUTING")
    report("Firewall rule is the first in the raw table", code == 0 and f"--dport {port}" in (out.splitlines()[1:2] or [""])[0])

    # --- API -------------------------------------------------------------------
    status, health = call(base, "GET", "/health", timeout=15)
    report("GET /health", status == 200 and health.get("status") == "ready", str(health))
    plan = "# Plan\n1. Delete old logs.\n## Diff\n+rm -rf /$LOG_DIR/*"
    status, v = call(base, "POST", "/verify", {"plan": plan})
    report("POST /verify", status == 200 and v.get("verdict") in ("approve", "changes") and v.get("summary"),
           f"verdict {v.get('verdict')}, {len(v.get('findings', []))} findings, {v.get('seconds')} s")
    report("POST /verify without a plan is refused", call(base, "POST", "/verify", {})[0] == 400)
    status, models = call(base, "GET", "/v1/models", timeout=10)
    report("GET /v1/models", status == 200 and models["data"][0]["id"] == model, model)

    def chat(content, max_tokens):
        return call(base, "POST", "/v1/chat/completions", {
            "model": model, "max_tokens": max_tokens, "temperature": 0,
            "messages": [{"role": "user", "content": content}]})
    status, r = chat("Is 17 a prime number? Answer yes or no.", 200)
    answer = r["choices"][0]["message"]["content"] if status == 200 else str(r)
    report("POST /v1/chat/completions", status == 200 and bool(answer), repr(answer.strip()))
    report("Thinking off", "<think>" not in answer and "</think>" not in answer)

    # --- Parallel --------------------------------------------------------------
    busy = []
    done = threading.Event()

    def watch():
        while not done.is_set():
            status, slots = call(f"http://127.0.0.1:{model_port}", "GET", "/slots", timeout=30)
            if status == 200:
                busy.append(sum(1 for s in slots if s.get("is_processing")))
            time.sleep(0.5)
    results = []

    def generate():
        results.append(call(base, "POST", "/v1/chat/completions", {
            "model": model, "max_tokens": 200, "ignore_eos": True, "temperature": 0,
            "messages": [{"role": "user", "content": f"Count upwards from {random.randint(1, 10**6)}."}]})[0])
    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()
    threads = [threading.Thread(target=generate) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    done.set()
    report("2 requests in parallel", results == [200, 200] and max(busy or [0]) >= 2,
           f"{results.count(200)} of 2 completed; at most {max(busy or [0])} at once")

    # --- Context ---------------------------------------------------------------
    if not args.skip_context:
        status, probe = chat(text(2000), 1)
        per_word = probe["usage"]["prompt_tokens"] / 2000
        status, r = chat(text(int((context - 1800) / per_word)), 16)
        tokens = r.get("usage", {}).get("prompt_tokens", 0) if status == 200 else 0
        report(f"Serves a {tokens}-token prompt", status == 200 and tokens > context - 3000, "" if status == 200 else str(r))
        status, r = chat(text(int((context + 1500) / per_word)), 16)
        report(f"Refuses a prompt over {context} tokens", status == 400 and "exceed_context_size_error" in str(r), str(r))
        status, r = call(base, "POST", "/verify", {"plan": text(int((context + 1500) / per_word))})
        report("POST /verify refuses a plan over the context with 413", status == 413, f"HTTP {status}")

    # --- GPU -------------------------------------------------------------------
    # This llama.cpp does not log layer offload, so measure the GPU while it works.
    tegra = subprocess.Popen(["tegrastats", "--interval", "1000"], stdout=subprocess.PIPE, universal_newlines=True)
    status = chat("Count upwards from 1.", 64)[0]
    tegra.terminate()
    load = [int(x) for x in re.findall(r"GR3D_FREQ (\d+)%", tegra.communicate()[0])]
    report("Generation runs on the GPU", status == 200 and max(load or [0]) >= 50, f"peak GPU load {max(load or [0])}%")

    # --- Crash recovery --------------------------------------------------------
    if args.test_restart:
        for name, svc in (("Vera", vera), ("llama-server", model_svc)):
            pid = main_pid(svc)
            code, out = run("kill", "-9", pid)
            print(f"INFO  killed {name} (pid {pid}); waiting for {svc} to restart it")
            time.sleep(15)
            back = wait_ready(base)
            new = main_pid(svc)
            report(f"{name} restarts after a crash", code == 0 and back and new != pid, f"new pid {new}")

    print("Result: " + (f"{failures} check(s) failed" if failures else "all checks passed"))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
