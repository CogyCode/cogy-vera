# Vera: OpenVINO build

This build runs Vera, CogyServer's verifier, on a Windows PC with an Intel GPU.
It uses [OpenVINO Model Server](https://github.com/openvinotoolkit/model_server)
(OVMS) and Qwen3.6-35B-A3B, quantised to INT4.

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
| Model | [`OpenVINO/Qwen3.6-35B-A3B-int4-ov`](https://huggingface.co/OpenVINO/Qwen3.6-35B-A3B-int4-ov): mixture of experts, 35B parameters with about 3B active per token, INT4 weights |
| Model server | OVMS 2026.4.0 on `localhost:18811`, reachable only from this PC |
| Vera service | [vera/vera.py](vera/vera.py): Python 3.12, standard library only |
| Device | Intel GPU |
| Context | 65,536 tokens per request (prompt plus output) |
| Concurrency | 2 requests in parallel |
| Thinking | Off by default |
| Endpoint | `http://<private-address>:8811` on CogyServer's private network |
| Access | Windows Firewall admits port 8811 from CogyServer only |
| Services | `CogyVera` (Vera) and `CogyVeraModel` (OVMS): both start at boot and restart after a failure |

```
CogyServer ──► CogyVera  (<private-address>:8811) ──► CogyVeraModel  (localhost:18811) ──► GPU
               vera.py, run by WinSW                  ovms.exe
```

## Requirements

| | |
|---|---|
| OS | Windows 10 or 11, x64 |
| GPU | Intel GPU with a current driver. Tested on a Core Ultra 7 258V (Arc 140V). |
| Memory | 32 GB RAM. The model needs about 20 GB of GPU memory, which is more than Windows' default limit of half the RAM. If the model fails to load, raise the limit with **Shared GPU Memory Override** in Intel Graphics Software. |
| Disk | About 20 GB free |
| Network | Access to CogyServer's private network, and a join key if this PC is not on it yet |
| Rights | Administrator. The scripts ask through UAC. |

## Installation

Run both steps from this directory in PowerShell.

### Step 1: Join the private network

Skip this step if the PC is already on CogyServer's network.

1. Get a join key from **CogyServer › Machines › Add a machine to the network**.
2. Run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\join-network.ps1 -LoginServer http://<server-ip>:8780 -AuthKey <key>
   ```

   Give CogyServer's IP address, not a `.local` name. The Tailscale service runs
   as SYSTEM and may not resolve mDNS names.

[join-network.ps1](join-network.ps1) does the following:
- installs Tailscale if it is missing, after checking its signature;
- joins the network with `--unattended`, so the connection survives reboots and
  logoffs;
- does nothing if the PC is already joined.

The join key is never written to a command line or a log.

### Step 2: Install Vera

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -AllowFrom <cogyserver-address>
```

`-AllowFrom` is CogyServer's private address, the only one admitted to the API
port. No address is kept in this repository. The installer stops if the PC is not
on the private network. It is safe to re-run, for example to upgrade or repair; a
re-run can leave out `-AllowFrom` and keeps the address in the installed firewall
rule. It performs these steps:

1. **Model server:** downloads OVMS (pinned, SHA-256 checked) to `%ProgramData%\CogyVera\ovms`.
2. **Model:** downloads the model (about 19 GB) to `%ProgramData%\CogyVera\models`.
   It checks that the download is complete and removes models that are no
   longer configured.
3. **Configuration:** installs [config/config.json](config/config.json) and
   [config/graph.pbtxt](config/graph.pbtxt), sets the model's context to 64k,
   and makes thinking default to off in the chat template.
4. **Network:** reads this PC's private address from Tailscale.
5. **Firewall:** adds the rule group *Cogy Vera*, which allows TCP 8811 from
   CogyServer and blocks it from every other source.
6. **Python and Vera:** installs Python 3.12 (embeddable, pinned, SHA-256
   checked) and [vera/](vera/) to `%ProgramData%\CogyVera`.
7. **Services:** creates the two services:
   - `CogyVeraModel` runs OVMS, bound to `localhost`.
   - `CogyVera` runs Vera through [WinSW](https://github.com/winsw/winsw),
     bound to the private address. It is set to delayed start and waits for
     OVMS and Tailscale.
8. **Self-test:** waits for the model to load, then tests `/health`, `/verify`
   and a chat completion.

When it finishes, the installer prints Vera's endpoint. The full log is in
`%ProgramData%\CogyVera\logs\install.log`.

## API reference

Base URL: `http://<private-address>:8811`

| Method | Path | Description |
|---|---|---|
| `POST` | `/verify` | Review a plan and return a verdict |
| `GET` | `/health` | Service and model status |
| `GET` | `/v3/models` | OpenAI API: list models (passed through to OVMS) |
| `POST` | `/v3/chat/completions` | OpenAI API: chat completion (passed through to OVMS, streaming supported) |

`/v1/...` paths are passed through in the same way as `/v3/...`. The model name
for OpenAI requests is `OpenVINO/Qwen3.6-35B-A3B-int4-ov`.

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
| `502` | The model server is unreachable, or no valid verdict came back after the retry |
| `503` | The model is still loading |

### `GET /health`

```json
{"service": "vera", "status": "ready", "model": "OpenVINO/Qwen3.6-35B-A3B-int4-ov", "detail": null}
```

Returns `200` when the model is loaded and `503` otherwise.

### OpenAI passthrough

Requests go to OVMS unchanged. Thinking is off. To turn it on for one request,
add `"chat_template_kwargs": {"enable_thinking": true}`. Passthrough requests
do not get `/verify`'s output limit, so set `max_tokens` on them.

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
  [config/verdict.schema.json](config/verdict.schema.json) (`response_format`,
  strict JSON schema).
- **Field order:** `analysis` comes first, so the model reasons before it
  commits to findings, and `verdict` comes last, so it follows from them.
- **Prompt:** [config/review-prompt.txt](config/review-prompt.txt) has the model
  draft each fix and check it against edge cases, such as empty variables and
  over-long input, before writing the findings.
- **Validation:** Vera checks every reply against the schema and retries once
  at a higher temperature if it is invalid.
- **Consistency:** a verdict of `approve` that comes with findings is changed to
  `changes`, and `verdict_overridden` is set.

## Configuration

All settings live in the build directory. Edit them, then re-run `install.ps1`.

| File | Contents |
|---|---|
| [config/settings.psd1](config/settings.psd1) | Service names, ports, pinned versions and hashes, model, context length, output limit |
| [config/config.json](config/config.json) | OVMS model list |
| [config/graph.pbtxt](config/graph.pbtxt) | OVMS LLM pipeline: device, KV cache size and precision, request slots, prefix caching |
| [config/service.xml](config/service.xml) | WinSW service definition for Vera |
| [config/review-prompt.txt](config/review-prompt.txt) | Review system prompt |
| [config/verdict.schema.json](config/verdict.schema.json) | Verdict JSON schema |

### GPU memory

| Item | Size |
|---|---|
| Weights | About 18 GB |
| KV cache | 2 GB, set by `cache_size`, at u8 precision |
| OVMS process in total | About 20 GB of shared GPU memory |

Only 10 of the model's 40 layers use full attention, so two requests at the
full 64k context need about 1.3 GB of the KV cache. On a 32 GB PC, about
4 GB of RAM is left for everything else.

## Performance

Measured with [scripts/benchmark.ps1](scripts/benchmark.ps1) on a Core Ultra 7
258V, Arc 140V, 32 GB, OVMS 2026.4.0 and driver 32.0.101.8860:

| Metric | Result |
|---|---|
| Prompt processing, 8,000-token prompt | 487 tok/s median (range 457–491); about 16 s to the first token |
| Generation, 1 request | 18 tok/s |
| Generation, 2 requests at once | About 10 tok/s each (20 tok/s in total) |
| Typical `/verify` review | About 30 s (about 350 prompt and 530 output tokens) |

Generation is limited by memory bandwidth. Two requests at once share it, so
each gets about half the speed.

## Operations

### Services

| Service | Runs | Listens on | Start | On failure |
|---|---|---|---|---|
| `CogyVeraModel` | `ovms.exe` | `localhost:18811` | Automatic | Restart |
| `CogyVera` | `vera.py` (WinSW) | `<private-address>:8811` | Automatic (delayed), after OVMS and Tailscale | Restart |

```powershell
Get-Service CogyVera, CogyVeraModel
Restart-Service CogyVeraModel, CogyVera
```

The model takes about a minute to load after a start. Until then, `/health`
returns `503`.

### Logs

In `%ProgramData%\CogyVera\logs`:

| File | Contents |
|---|---|
| `install.log` | Installer output |
| `join-network.log` | Network join output, with the key removed |
| `vera.log` | Vera: startup, and each verdict with its timing and token counts (rotated at 5 MB) |
| `ovms.log` | Model server: model loading, and the request queue and KV cache usage |
| `CogyVera.*.log` | WinSW service wrapper |
| `verify.log` | Output of the last [verify.ps1](scripts/verify.ps1) run |

### Troubleshooting

| Symptom | Check |
|---|---|
| `/health` returns `503` | The model is still loading. Watch `ovms.log`. |
| The model fails to load | GPU memory limit: see [Requirements](#requirements) |
| CogyServer cannot connect | Run `tailscale status`, check that the *Cogy Vera* firewall rules exist, and run `scripts\verify.ps1` |
| Requests are slow | In `ovms.log`, look at `All requests` (queued) and `Scheduled requests` (running). Long passthrough requests without `max_tokens` hold a slot. |

## Testing

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1 [-TestRestart]
powershell -ExecutionPolicy Bypass -File .\scripts\test-verdict.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\benchmark.ps1
& "$env:ProgramData\CogyVera\python\python.exe" -m unittest discover -s vera
```

| Test | Checks |
|---|---|
| [scripts/verify.ps1](scripts/verify.ps1) | **Services:** both running, start at boot, restart on failure, and start in the right order. **Network:** listen addresses and firewall rules. **API:** `/health`, `/verify` and the OpenAI passthrough. **Model:** thinking is off and 2 requests run in parallel. **Context:** a prompt just under 64k tokens is served, and one just over is refused. With `-TestRestart`, it also kills both processes and checks that they come back. |
| [scripts/test-verdict.ps1](scripts/test-verdict.ps1) | Sends [a test plan](scripts/testdata/plan-with-hashes.md) that has two real defects: an `rm -rf /$CACHE_DIR` that wipes `/` when the variable is empty, and an unbounded `strcpy`. It checks the JSON, that `#` characters survive, that both defects are found with fixes that hold, and that the verdict is `changes`. |
| [scripts/benchmark.ps1](scripts/benchmark.ps1) | Prompt processing and generation speed, and GPU memory |
| [vera/test_vera.py](vera/test_vera.py) | Unit tests for Vera's service, against a simulated model server |

## Uninstalling

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1                # services and firewall rules
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -RemoveFiles   # also %ProgramData%\CogyVera
```

`-RemoveFiles` also deletes OVMS, the model, Python, Vera's code and the logs.
The PC stays on the private network. To leave it, run `tailscale logout`.

## Repository layout

```
openvino/
├── join-network.ps1          Step 1: join CogyServer's private network
├── install.ps1               Step 2: install Vera
├── uninstall.ps1             Remove Vera
├── config/                   Settings, OVMS configuration, service definition, prompt, schema
├── lib/common.ps1            Helpers shared by the scripts
├── vera/                     Vera's service (vera.py) and its unit tests
└── scripts/                  Requirement checks, verdict test, benchmark, test data
```
