![Cogy Vera: review plans and code for Cogy AI agents](assets/banners/cogy-vera-banner-1920x1080.jpg)

# Cogy Vera

Vera is the verifier in the Cogy system. Before Cogy Server carries out a plan,
it sends the plan to Vera, along with the diff when there is one. She reviews
it for defects and returns a structured verdict:

- **`approve`**: no problems found.
- **`changes`**: a list of findings, each with the file, the line, the problem
  and a concrete fix.

Vera runs on her own machine on Cogy Server's private network and uses a
local language model. Plans and code never leave the network. Her installer
puts everything she needs on the machine: the model server, the model, Python,
the services and the firewall rules.

Vera is part of the Cogy system:

- [Cogy Code](https://github.com/CogyCode/cogy-code): secure, self-hosted
  software development with Cogy AI agents. Vera is the default verifier and
  reviewer for its jobs: she checks the brief, the plan and the finished work.
- [Cogy Server](https://github.com/CogyCode/cogy-server): identity, access and
  governance for Cogy AI agents. It runs the private network and is the only
  caller Vera admits.

## Before you install

**Install Cogy Code and Cogy Server first.** Vera does not work on her own:

1. **Cogy Server** must be installed and running. It runs the private network
   that Vera joins, gives out the join key, and is the only machine allowed to
   call Vera.
2. **Cogy Code** must be installed and connected to Cogy Server. Its jobs are
   what send plans and code to be verified.

Then install Vera on her own machine with the build's installer: see
[Builds](#builds).

## How it works

```
Cogy Server
    │  POST /verify  {plan, diff}
    ▼
Vera service (private address, port 8811)
    │  builds the review prompt, enforces the verdict schema,
    │  validates the reply and retries once if it is invalid
    ▼
Model server (local only)
    │
    ▼
Language model on the machine's GPU
```

- **Private:** Vera listens only on the machine's private network address, and
  the firewall admits only Cogy Server.
- **Structured:** every verdict follows a fixed JSON schema, so Cogy Server can
  act on it without parsing free text.
- **Standalone:** nothing else runs on the machine, so the model stays loaded
  and has the machine's memory to itself.
- **Unattended:** the services start at boot and restart after a failure.

## Devices

Vera is not made for one machine. Each build targets a kind of hardware: the
OpenVINO build any Windows PC with an Intel GPU, and the Xavier build the
NVIDIA Jetson AGX Xavier. The machines below are the ones she has been tested
on. Both run the same model, Qwen3.6-35B-A3B, on the device itself, with no
cloud service. It is a mixture-of-experts model: 35B parameters, with about
3B active for each token.

### Intel AI PC

An Intel AI PC is a laptop or desktop with an Intel Core Ultra processor,
which combines a CPU, a GPU and an NPU (neural processing unit) on one chip,
each able to run AI models. Vera has been tested on:

| | Core Ultra 7 258V ("Lunar Lake") |
|---|---|
| CPU | 8 cores (4 performance, 4 efficient), up to 4.8 GHz |
| GPU | Intel Arc 140V: 8 Xe2 cores, about 64 TOPS (INT8) |
| NPU | About 47 TOPS (INT8) |
| Memory | 32 GB LPDDR5X-8533 on the processor package, shared by the CPU, GPU and NPU |
| OS | Windows 11 |

The TOPS figures are Intel's, as published by Intel and in third-party spec
listings.

**Use in Vera.** The [openvino/](openvino/) build runs Qwen3.6-35B-A3B,
quantised to INT4, on the GPU through OpenVINO Model Server. Measured on the
258V, the build:

- processes a prompt at about 487 tokens a second, about 16 seconds to the
  first token of an 8,000-token prompt;
- generates about 18 tokens a second, or about 10 each with two requests at
  once;
- returns a typical verdict in about 30 seconds;
- needs about 20 GB of GPU memory, more than Windows gives the GPU by default
  on a 32 GB machine (see the build's README).

### NVIDIA Jetson AGX Xavier

The [Jetson AGX Xavier](https://developer.nvidia.com/embedded/jetson-agx-xavier-developer-kit)
is an embedded AI computer for robotics and edge AI:

| | Jetson AGX Xavier, 32 GB |
|---|---|
| CPU | 8-core NVIDIA Carmel (Armv8.2), up to 2.26 GHz |
| GPU | 512-core NVIDIA Volta, with 64 Tensor Cores |
| AI performance | 32 TOPS (INT8), NVIDIA's figure |
| Memory | 32 GB LPDDR4x, shared by the CPU and GPU |
| Storage | 32 GB eMMC |
| OS | JetPack 5 (Ubuntu 20.04, L4T R35), CUDA 11.4 |

**Use in Vera.** The [xavier/](xavier/) build runs Qwen3.6-35B-A3B, quantised
to Q4_K_M, on the GPU through llama.cpp built for CUDA. Measured on a 32 GB
module in MAXN power mode, the build:

- is a small, dedicated verifier that can sit on the network next to
  Cogy Server;
- processes a prompt at about 206 tokens a second, about 39 seconds to the
  first token of an 8,000-token prompt;
- generates about 19 tokens a second, or about 14 each with two requests at
  once;
- returns a typical verdict in about 20–30 seconds;
- uses about 20.7 GB of its memory for the model, so no other model can run
  on the machine alongside it.

### Which to use

| | Intel AI PC | Jetson AGX Xavier |
|---|---|---|
| Devices | Core Ultra 7 258V | Jetson AGX Xavier, 32 GB |
| Model | Qwen3.6-35B-A3B (INT4), on the GPU | Qwen3.6-35B-A3B (Q4_K_M), on the GPU |
| Context | 65,536 tokens | 65,536 tokens |
| Prompt processing, 8,000 tokens | About 487 tok/s | About 206 tok/s |
| Generation, 1 request | About 18 tok/s | About 19 tok/s |
| Typical verdict | About 30 s | About 20–30 s |
| Requests at once | 2 | 2 |
| Long plans | Faster: prompts are read about twice as fast | Slower: a 63,000-token prompt takes about 9 minutes |

Both builds serve the same API (`POST /verify`, `GET /health` and the OpenAI
passthrough), so Cogy Server can use either.

## Builds

Each build directory is self-contained, with its own installer, configuration,
service code, tests and documentation. Builds share no files, so each can be
versioned and deployed independently.

| Build | Platform | Model server | Model | Status |
|---|---|---|---|---|
| [openvino/](openvino/) | Intel GPU, Windows | OpenVINO Model Server 2026.4 | Qwen3.6-35B-A3B (INT4) | In service |
| [xavier/](xavier/) | NVIDIA Jetson AGX Xavier, CUDA, Ubuntu | llama.cpp | Qwen3.6-35B-A3B (Q4_K_M) | Installed |

See the build's README for requirements, installation, the API reference and
operations.

## Conventions

Every build follows these rules:

- **Scripted:** installation, configuration, testing and benchmarking are all
  scripts in the build directory. Nothing is set up by hand.
- **Portable:** no addresses or machine-specific values are committed. A
  machine's own address is discovered at install time. Cogy Server's address
  and join keys are given on the command line.
- **Pinned:** each download is fixed to a version and checked against its
  SHA-256 hash.
- **Re-runnable:** installers can be run again safely, and uninstallers remove
  everything they added.

## License

Copyright (C) 2026 CogniTech Systems LTD.

Cogy Vera is licensed under the MIT License. See [LICENSE](LICENSE).
