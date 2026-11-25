# Vera: Xavier build

This build runs Vera, CogyServer's verifier, natively on an NVIDIA Jetson AGX
Xavier. It uses [llama.cpp](https://github.com/ggml-org/llama.cpp) on the GPU
through CUDA, and Qwen3.6-35B-A3B, quantised to Q4_K_M.

## Contents

- [Overview](#overview)
- [Requirements](#requirements)
- [Installation](#installation)
- [API reference](#api-reference)
- [Verdict format](#verdict-format)
- [Configuration](#configuration)
- [Performance](#performance)
- [Operations](#operations)
- [Testing](#testing)
- [Uninstalling](#uninstalling)
- [Repository layout](#repository-layout)

## Overview

| | |
|---|---|
| Model | [`ggml-org/Qwen3.6-35B-A3B-GGUF`](https://huggingface.co/ggml-org/Qwen3.6-35B-A3B-GGUF), Q4_K_M: 19 GiB |
| Model name in the API | `ggml-org/Qwen3.6-35B-A3B-Q4_K_M` |
| Model server | `llama-server` on `localhost:18811`, reachable only from this machine |
| Vera service | [vera/vera.py](vera/vera.py): system Python 3.8, standard library only |
| Device | Xavier GPU, all layers, CUDA 11.4 |
| Context | 65,536 tokens per request (prompt plus output) |
| Concurrency | 2 requests in parallel |
| Thinking | Off by default |
| Endpoint | `http://<private-address>:8811` on CogyServer's private network |
| Access | An iptables rule drops port 8811 from everything except CogyServer |
| Services | `cogy-vera`, `cogy-vera-model`, `cogy-vera-firewall`: all start at boot; the first two restart after a failure |

```
CogyServer ──► cogy-vera               ──► cogy-vera-model ──► GPU
               <private-address>:8811      localhost:18811
               vera.py                     llama-server (CUDA)
```

## Requirements

| | |
|---|---|
| Hardware | Jetson AGX Xavier, 32 GB. Tested on the 32 GB module in MAXN power mode. |
| OS | JetPack 5 (Ubuntu 20.04, L4T R35) with CUDA 11.4 from `nvidia-jetpack`. Tested on JetPack 5.1.6. |
| Memory | 23 GB available before install. The model takes about 20.7 GB, which leaves about 3 GB. **No other model can run alongside it**, including Kev (see below). |
| Disk | About 25 GB free on the disk holding `DATA_DIR` (default `/models/cogy-vera`) |
| Network | Access to CogyServer's private network, and a join key if this machine is not on it yet |
| Rights | `sudo` |

### Kev

This machine's `cogy-system1` service (Kev) uses about 12 GB of GPU memory, so
it cannot run at the same time as Vera. `install.sh` stops if Kev is running,
and warns if it is stopped but still enabled. If Kev starts at the next boot,
the two compete for memory. To keep it off:

```bash
sudo systemctl disable --now cogy-system1
```

Vera never changes that service. Stopping Kev removes the firewall decision
model that CogyServer reaches at port 8813.

## Installation

### Step 1: Join the private network

Skip this step if the machine is already on CogyServer's network.

```bash
sudo ./join-network.sh --login-server http://<server-ip>:8780 --auth-key <key>
```

[join-network.sh](join-network.sh) does nothing if the machine is already
joined. Otherwise it installs Tailscale from its signed apt repository if
needed, and joins. The key is passed through a file, so it does not appear in
the process list or a log.

### Step 2: Install Vera

```bash
sudo ./install.sh --allow-from <cogyserver-address>
```

`--allow-from` is CogyServer's private address, the only one admitted to Vera's
port. No address is kept in this repository. The installer is safe to re-run, for
example to upgrade or repair; a re-run can leave out `--allow-from` and keeps the
address in the installed firewall rule. It performs these steps:

1. **Checks:** Jetson, CUDA, private network, memory, and no conflicting service.
2. **llama.cpp:** fetches the pinned commit and builds `llama-server` for CUDA,
   which takes about 25 minutes, using a pinned, SHA-256 checked CMake. Installs
   it to `/opt/cogy-vera/llama`.
3. **Model:** downloads the pinned revision (19 GiB) to
   `/models/cogy-vera/models` and checks its SHA-256. It removes any other model
   in that directory.
4. **Code:** creates the `cogy-vera` account and installs Vera and its
   configuration to `/opt/cogy-vera`.
5. **Services:** installs and starts the three systemd services.
6. **Self-test:** waits for the model to load, then tests `/health`, `/verify`
   and a chat completion.

When it finishes, it prints Vera's endpoint. The full log is in
`/var/log/cogy-vera/install.log`.

## API reference

Base URL: `http://<private-address>:8811`

| Method | Path | Description |
|---|---|---|
| `POST` | `/verify` | Review a plan and return a verdict |
| `GET` | `/health` | Service and model status |
| `GET` | `/v1/models` | OpenAI API: list models |
| `POST` | `/v1/chat/completions` | OpenAI API: chat completion, streaming supported |
| `POST` | `/v1/completions` | OpenAI API: text completion |

### `POST /verify`

Request:

| Field | Type | Required | Description |
|---|---|---|---|
| `plan` | string | Yes | The plan to review |
| `diff` | string | No | The code change that goes with the plan |

```bash
curl -s http://<private-address>:8811/verify \
  -H "Content-Type: application/json" \
  -d '{"plan": "# Plan\n1. Wipe the cache", "diff": "+rm -rf /$CACHE_DIR"}'
```

Response (`200`): the [verdict](#verdict-format), plus these fields:

| Field | Description |
|---|---|
| `model` | Model that produced the verdict |
| `seconds` | Time taken |
| `usage` | Prompt and completion token counts |
| `attempts` | Number of model calls (2 if the first reply was invalid) |
| `verdict_overridden` | `true` if Vera changed the verdict to `changes` because there were findings |

Errors return `{"error": "<message>"}`:

| Status | Meaning |
|---|---|
| `400` | The body is not JSON, `plan` is missing or empty, or `diff` is not a string |
| `413` | The body is over 4 MB, or the plan is too long for the 64k context |
| `502` | `llama-server` is unreachable or returned an error, or no valid verdict came back after the retry |
| `503` | The model is still loading |

### `GET /health`

```json
{"service": "vera", "status": "ready", "model": "ggml-org/Qwen3.6-35B-A3B-Q4_K_M", "detail": null}
```

Returns `200` when the model is loaded and `503` otherwise.

### OpenAI passthrough

Thinking is off. To turn it on for one request, add
`"chat_template_kwargs": {"enable_thinking": true}`; the reasoning comes back in
`reasoning_content`. Passthrough requests do not get `/verify`'s output limit, so
set `max_tokens` on them.

## Verdict format

```json
{
  "analysis": "Reasoning, written before the findings",
  "findings": [
    {"file": "path/to/file", "line": 42, "problem": "What is wrong", "fix": "How to fix it"}
  ],
  "summary": "One or two sentences, suitable for an issue comment",
  "verdict": "changes"
}
```

`verdict` is `approve` or `changes`. Several things keep verdicts reliable:

- **Schema:** the model's output is constrained to
  [config/verdict.schema.json](config/verdict.schema.json).
- **Field order:** `analysis` comes first and `verdict` comes last, so the
  verdict follows from the reasoning.
- **Prompt:** [config/review-prompt.txt](config/review-prompt.txt).
- **Validation:** Vera checks every reply against the schema and retries once at
  a higher temperature if it is invalid.
- **Consistency:** `approve` with findings is changed to `changes`, and
  `verdict_overridden` is set. `changes` with no findings is invalid and is
  retried, because CogyServer would have nothing to act on.

**Limits of the model.** Verdicts are not always right. At temperature 0, which
Vera uses, the test plans pass on every run, but the result can change with small
edits to the prompt. At temperature 0.3, the two-defect plan passed 7 of 8 runs;
the failure replaced the `strcpy` fix with a comment. Treat a verdict as a
review, not a proof.

## Configuration

All settings live in the build directory. Edit them, then re-run `install.sh`.

| File | Contents |
|---|---|
| [config/settings.env](config/settings.env) | Service names, paths, ports, pinned versions and hashes, model, context, slots, output limit, memory requirement |
| [config/cogy-vera.service](config/cogy-vera.service) | systemd service for Vera |
| [config/cogy-vera-model.service](config/cogy-vera-model.service) | systemd service for `llama-server`: its options, such as thinking off |
| [config/cogy-vera-firewall.service](config/cogy-vera-firewall.service) | systemd service holding the firewall rule |
| [config/review-prompt.txt](config/review-prompt.txt) | Review system prompt |
| [config/verdict.schema.json](config/verdict.schema.json) | Verdict JSON schema |

### Firewall

The rule is in iptables' `raw` table:

```
-t raw -I PREROUTING -p tcp --dport 8811 ! -i lo ! -s <cogyserver-address> -j DROP
```

It is not in the `filter` table because Tailscale accepts everything from the
private network there, and puts its chain first each time it restarts. systemd's
`IPAddressDeny=` is not used because this kernel has no `CONFIG_CGROUP_BPF`, so
systemd would ignore it. Loopback stays allowed for the local checks.

## Performance

Measured with [scripts/benchmark.py](scripts/benchmark.py) on a 32 GB AGX Xavier
in MAXN mode, JetPack 5.1.6, llama.cpp `a4cb4c6`:

| Metric | Result |
|---|---|
| Prompt processing, 8,000-token prompt | 206 tok/s median (range 206–208); about 39 s to the first token |
| Prompt processing, 63,000-token prompt | About 8.7 minutes in total |
| Generation, 1 request | 19.2 tok/s |
| Generation, 2 requests at once | 14.4 tok/s each (28.7 tok/s in total) |
| Typical `/verify` review | About 20–30 s (about 350 prompt and 400–550 output tokens) |
| Model load | About 35 s when the file is in the page cache; longer after a boot |
| Memory | About 20.7 GB; about 3.3 GB left available on the machine |

Prompt speed falls as the prompt grows, so very long plans take much longer per
token. `TIMEOUT` in the settings allows 30 minutes for one model reply.

## Operations

### Services

| Service | Runs | Listens on | On failure |
|---|---|---|---|
| `cogy-vera-firewall` | `iptables`, once | | |
| `cogy-vera-model` | `llama-server` | `localhost:18811` | Restart |
| `cogy-vera` | `vera.py` | `<private-address>:8811` | Restart |

```bash
systemctl status cogy-vera cogy-vera-model cogy-vera-firewall
sudo systemctl restart cogy-vera-model cogy-vera
```

The model takes about 35 s to load after a start. Until then, `/health` returns
`503`.

### Logs

In `/var/log/cogy-vera`:

| File | Contents |
|---|---|
| `install.log` | Installer output |
| `build.log` | llama.cpp build output |
| `vera.log` | Vera: startup, and each verdict with its timing and token counts (rotated at 5 MB) |

`llama-server`'s output, including each request's progress, is in the journal:
`journalctl -u cogy-vera-model`.

### Troubleshooting

| Symptom | Check |
|---|---|
| `/health` returns `503` | The model is still loading. Watch `journalctl -u cogy-vera-model -f`. |
| The model keeps restarting | Memory: run `free -m` and check that Kev is not running (`systemctl status cogy-system1`). |
| CogyServer cannot connect | Run `tailscale status` and `sudo iptables -t raw -S PREROUTING`, then `sudo python3 scripts/verify.py`. |
| Requests are slow | Run `curl -s localhost:18811/slots` on this machine: two busy slots mean new requests are queueing. Long passthrough requests without `max_tokens` hold a slot. Check the power mode with `nvpmodel -q`. |

## Testing

```bash
sudo python3 scripts/verify.py [--test-restart] [--skip-context]
python3 scripts/test-verdict.py
python3 scripts/benchmark.py
python3 -m unittest discover -s vera
```

| Test | Checks |
|---|---|
| [scripts/verify.py](scripts/verify.py) | **Services:** running, start at boot, restart on failure, start in the right order, and Kev not enabled. **Network:** listen addresses and the firewall rule. **API:** `/health`, `/verify` and the OpenAI passthrough. **Model:** thinking is off, 2 requests run in parallel, and generation loads the GPU. **Context:** a prompt just under 64k tokens is served and one just over is refused; this part takes about 10 minutes. With `--test-restart`, it also kills both services and checks that they come back. |
| [scripts/test-verdict.py](scripts/test-verdict.py) | Sends [a test plan](scripts/testdata/plan-with-hashes.md) with two real defects: an `rm -rf /$CACHE_DIR` and an unbounded `strcpy`. It checks the JSON, that `#` characters survive, that both defects are found with fixes that hold, and that the verdict is `changes`. It also checks that SQL injection gets a parameterised fix and that a harmless change is approved. |
| [scripts/benchmark.py](scripts/benchmark.py) | Prompt processing and generation speed, and memory |
| [vera/test_vera.py](vera/test_vera.py) | Unit tests for Vera's service, against a simulated `llama-server` |

## Uninstalling

```bash
sudo ./uninstall.sh                 # services and firewall rule
sudo ./uninstall.sh --remove-files  # also /opt/cogy-vera, /models/cogy-vera, the logs and the account
```

`--remove-files` deletes the 19 GiB model and the llama.cpp build. The machine
stays on the private network, and Kev is not touched. To bring Kev back, run
`sudo systemctl enable --now cogy-system1`.

## Repository layout

```
xavier/
├── join-network.sh           Step 1: join CogyServer's private network
├── install.sh                Step 2: install Vera
├── uninstall.sh              Remove Vera
├── config/                   Settings, systemd services, prompt, schema
├── vera/                     Vera's service (vera.py) and its unit tests
└── scripts/                  Requirement checks, verdict test, benchmark, test data
```
