"""The installer's last step: one verdict and one chat through Vera.

    python3 selftest.py <base-url> <model>
"""

import sys

from common import call


def main():
    base, model = sys.argv[1:3]
    plan = "# Plan\n1. Add a README.md with the project name.\n## Diff\n--- /dev/null\n+++ b/README.md\n@@ -0,0 +1 @@\n+# Demo"
    status, r = call(base, "POST", "/verify", {"plan": plan})
    if status != 200 or r.get("verdict") not in ("approve", "changes"):
        sys.exit(f"POST /verify gave no verdict: HTTP {status}: {r}")
    print(f"    POST /verify: {r['verdict']}, {len(r['findings'])} findings, {r['seconds']} s")

    status, r = call(base, "POST", "/v1/chat/completions", {
        "model": model, "max_tokens": 64, "temperature": 0,
        "messages": [{"role": "user", "content": "Reply with exactly: OK"}]})
    if status != 200:
        sys.exit(f"chat failed: HTTP {status}: {r}")
    answer = r["choices"][0]["message"]["content"]
    if "<think>" in answer or "</think>" in answer:
        sys.exit(f"thinking is still on; reply was: {answer}")
    print(f"    Chat passthrough OK, no thinking: {answer.strip()!r}")


if __name__ == "__main__":
    main()
