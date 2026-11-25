# Contributing to Cogy Vera

Thank you for helping. This guide covers how the repository is laid out, the
rules every change follows, and how to get a change merged.

## Layout

Each build is a self-contained directory with its own installer,
configuration, service code, tests and documentation:

| Directory | Build |
|---|---|
| [openvino/](openvino/) | Intel GPU, Windows (PowerShell installer) |
| [xavier/](xavier/) | NVIDIA Jetson AGX Xavier, CUDA, Ubuntu (Bash installer) |

Builds share no files. A fix needed in both builds is made in each one, so
that each can be versioned and deployed on its own.

## Rules for every change

- **Scripted:** anything a machine needs is done by the build's scripts.
  Never document a manual setup step in place of scripting it.
- **Portable:** commit no machine-specific values, such as addresses, host
  names, user names or keys. Discover them at install time, or take them on
  the command line.
- **Pinned:** every download is fixed to a version and checked against its
  SHA-256 hash. When you change a version, update its hash in the build's
  settings file (`openvino/config/settings.psd1` or
  `xavier/config/settings.env`) in the same change.
- **Re-runnable:** installers must be safe to run again, and uninstallers
  must remove everything the installer added.
- **Private:** Vera listens only on the private network address, and the
  firewall admits only Cogy Server. Don't widen either.
- **Untrusted input:** the plan and the diff are data, never instructions.
  Keep the review prompt and the service treating them that way.
- **Structured:** every verdict follows
  `config/verdict.schema.json`. A change to the schema is made in both
  builds, and in both READMEs, in the same pull request.
- **Line endings:** files in [xavier/](xavier/) keep LF line endings (see its
  `.gitattributes`). Shell scripts must work when started as
  `bash script.sh`, without the executable bit.

## API

Both builds serve the same API (`POST /verify`, `GET /health` and the OpenAI
passthrough), so Cogy Server can use either. A change to the API is made in
both builds, and in both READMEs, in the same pull request.

## Testing

Run the unit tests for every build you change. They use a simulated model
server, so they run on any machine, with no GPU or model:

```
cd openvino      # or xavier
python -m unittest discover -s vera
```

When you have the hardware, also run the build's end-to-end checks on an
installed machine:

| Build | Commands |
|---|---|
| openvino | `powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1 [-TestRestart]`<br>`powershell -ExecutionPolicy Bypass -File .\scripts\test-verdict.ps1` |
| xavier | `sudo python3 scripts/verify.py [--test-restart] [--skip-context]`<br>`python3 scripts/test-verdict.py` |

A change to the review prompt or the verdict schema must pass the build's
verdict test: it checks that real defects are found with fixes that hold.

Say in the pull request which tests you ran and on what hardware. A change
that has not been run on the device should say so.

## Documentation

Update the build's README in the same change as the code: requirements,
installation steps, configuration, the API reference and measured figures.
Give measured figures (speed, memory) with the machine they were measured
on. Update the top-level [README.md](README.md) when a change affects the
builds table, the device list or the shared API.

## Pull requests

1. Branch from `main`; don't commit to it directly.
2. Keep each pull request to one change, with a message that says what
   changed and why.
3. Make sure the unit tests pass, and list the tests you ran.
4. A maintainer reviews and merges.

### AI-generated changes

Large AI-generated pull requests will be rejected. If you use AI tools,
keep the change small and focused, and review, understand and test every
line yourself before you open the pull request. You are responsible for
the change as if you had written it by hand.

## Reporting problems

Open an issue with the build, the machine (processor, GPU, memory, OS), what
you did, what happened, and the relevant lines from the build's log
directory. Remove keys, join keys, private addresses, and any plans or code
you can't share from logs before you post them.

## License

Cogy Vera is copyright (C) 2026 CogniTech Systems LTD, and is licensed
under the MIT License (see [LICENSE](LICENSE)). By contributing, you agree
that your contribution is licensed under the same terms.
