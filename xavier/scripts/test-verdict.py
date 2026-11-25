#!/usr/bin/env python3
"""Tests the review verdict: format and judgement.

Sends testdata/plan-with-hashes.md to POST /verify. The plan has two real
problems (rm -rf /$CACHE_DIR wipes / when the variable is empty; strcpy into a
buffer of unknown size). Each run must:
  - return JSON with exactly the verdict's fields, plus those Vera adds
  - keep '#' characters intact
  - find both problems, with fixes that hold
  - give verdict "changes"
Then two more plans, once each: SQL built by string concatenation must get a
finding with a parameterised fix, and a harmless typo fix must be approved.
Exit code 0 when everything passes.

    python3 test-verdict.py [--base-url URL] [--runs 3]
"""

import argparse
import json
import os
import re
import sys
import time

from common import HERE, XAVIER, call, default_base_url

META = {"verdict_overridden", "model", "seconds", "usage", "attempts"}


def check(v, schema):
    errs = []
    want = set(schema["required"])
    for k in want - set(v):
        errs.append(f"missing {k}")
    for k in set(v) - want - META:
        errs.append(f"extra field {k}")
    findings = v.get("findings", [])
    for f in findings:
        for k in ("file", "line", "problem", "fix"):
            if k not in f:
                errs.append(f"finding missing {k}")
        if not isinstance(f.get("line"), int):
            errs.append("finding line not an integer")
    if v.get("verdict") != "changes":
        errs.append(f"expected verdict 'changes', got {v.get('verdict')!r}")

    rm = next((f for f in findings if "rm -rf" in f.get("problem", "")), None)
    if not rm:
        errs.append("missed rm -rf /$CACHE_DIR")
    elif not re.search(r":\?|-z |-n |if ", rm.get("fix", "")):
        errs.append(f"rm -rf fix does not stop on an empty CACHE_DIR: {rm.get('fix')}")

    cp = next((f for f in findings if "strcpy" in f.get("problem", "")), None)
    if not cp:
        errs.append("missed strcpy overflow")
    else:
        fix = cp.get("fix", "")
        if re.search(r"sizeof\s*\(\s*d\s*\)", fix):
            errs.append(f"strcpy fix uses sizeof(d) on a pointer: {fix}")
        elif re.match(r"\s*strcpy\(d, s\);", fix):
            errs.append("strcpy fix is unchanged")
        elif not re.search(r"read_key\s*\([^)]*,[^)]*,", fix) and not re.search(r"\b[A-Z][A-Z0-9_]{2,}\b", fix):
            errs.append(f"strcpy fix does not take the buffer size from the caller or a named constant: {fix}")
    for f in findings:
        if "\\n" in f.get("fix", ""):
            errs.append(f"literal \\n in fix for {f.get('file')}")
    if "#" not in json.dumps(v):
        errs.append("no '#' in the reply")
    return errs


SQL_PLAN = ("# Plan\n1. Add user lookup.\n## Diff\n--- a/db.py\n+++ b/db.py\n@@ -0,0 +1,2 @@\n"
            "+def find(cur, name):\n+    cur.execute(\"SELECT * FROM users WHERE name = '\" + name + \"'\")")
SAFE_PLAN = "# Plan\n1. Fix a typo in the README.\n## Diff\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-# Helo\n+# Hello"


def check_other_plans(base):
    """How many of the two extra plans failed."""
    failed = 0
    status, v = call(base, "POST", "/verify", {"plan": SQL_PLAN})
    fixes = [f["fix"] for f in v.get("findings", [])] if status == 200 else []
    if v.get("verdict") == "changes" and any(re.search(r"(%s|\?|:\w+).*,", fix) and "+ name" not in fix for fix in fixes):
        print(f"PASS  SQL injection found and fixed ({v['seconds']} s)")
    else:
        print(f"FAIL  SQL injection: HTTP {status}: {v}")
        failed += 1
    status, v = call(base, "POST", "/verify", {"plan": SAFE_PLAN})
    if status == 200 and v["verdict"] == "approve" and not v["findings"]:
        print(f"PASS  harmless change approved ({v['seconds']} s)")
    else:
        print(f"FAIL  harmless change: HTTP {status}: {v}")
        failed += 1
    return failed


def main():
    ap = argparse.ArgumentParser(description="Tests the review verdict")
    ap.add_argument("--base-url")
    ap.add_argument("--runs", type=int, default=3)
    args = ap.parse_args()
    base = args.base_url or default_base_url()
    with open(os.path.join(XAVIER, "config", "verdict.schema.json"), encoding="utf-8") as f:
        schema = json.load(f)
    with open(os.path.join(HERE, "testdata", "plan-with-hashes.md"), encoding="utf-8") as f:
        plan = f.read().strip()

    failed = 0
    for run in range(1, args.runs + 1):
        started = time.monotonic()
        status, v = call(base, "POST", "/verify", {"plan": plan})
        secs = round(time.monotonic() - started, 1)
        if status != 200:
            print(f"FAIL  run {run}: HTTP {status}: {v}")
            failed += 1
            continue
        if run == 1:
            print(f"Model: {v['model']}")
            print(json.dumps(v, indent=2, ensure_ascii=False))
        errs = check(v, schema)
        tokens = v["usage"]["completion_tokens"]
        if errs:
            print(f"FAIL  run {run} ({secs} s, {tokens} tokens): " + "; ".join(errs))
            failed += 1
        else:
            note = ", verdict overridden by Vera" if v["verdict_overridden"] else ""
            print(f"PASS  run {run} ({secs} s, {tokens} tokens, attempts {v['attempts']}): "
                  f"verdict {v['verdict']}, {len(v['findings'])} findings{note}")
    failed += check_other_plans(base)
    print("Result: " + (f"{failed} check(s) failed" if failed else "all checks passed"))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
