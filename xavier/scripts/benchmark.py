#!/usr/bin/env python3
"""Measures prompt processing and generation speed, and memory.

Each trial uses a fresh random prefix so prompt caching cannot skip the prompt:
    prompt processing tok/s = prompt tokens / time to first token
    generation tok/s        = (completion tokens - 1) / (last token - first token)

    python3 benchmark.py [--base-url URL] [--prompt-tokens 8000] [--gen-tokens 256] [--trials 3]
"""

import argparse
import json
import random
import statistics
import threading
import time
import uuid

from common import call, connect, default_base_url

WORDS = ("plan step verify check order task resource budget risk owner deadline input output "
         "state goal constraint result review assume depend fail retry safe cost time data "
         "server client queue cache limit rule test ensure valid error report").split()


def new_prompt(n_words):
    words = [random.choice(WORDS) + (". " if i % 12 == 11 else " ") for i in range(n_words)]
    return f"Run {uuid.uuid4()}. Notes: " + "".join(words) + "\n\nWrite a long, detailed summary of the notes above."


def stream_chat(base, model, prompt, max_tokens):
    """(seconds to first token, seconds to last token, usage)."""
    body = {"model": model, "stream": True, "max_tokens": max_tokens, "ignore_eos": True, "temperature": 0,
            "stream_options": {"include_usage": True}, "messages": [{"role": "user", "content": prompt}]}
    conn = connect(base)
    started = time.monotonic()
    conn.request("POST", "/v1/chat/completions", body=json.dumps(body).encode("utf-8"),
                 headers={"Content-Type": "application/json"})
    resp = conn.getresponse()
    if resp.status != 200:
        raise RuntimeError(f"HTTP {resp.status}: {resp.read().decode('utf-8', 'replace')}")
    first = last = usage = None
    for line in resp:
        if not line.startswith(b"data: ") or line.strip() == b"data: [DONE]":
            continue
        chunk = json.loads(line[6:])
        if chunk.get("choices") and chunk["choices"][0].get("delta", {}).get("content"):
            last = time.monotonic() - started
            first = last if first is None else first
        usage = chunk.get("usage") or usage
    conn.close()
    return first, last, usage


def memory_mb():
    with open("/proc/meminfo", encoding="ascii") as f:
        info = {line.split(":")[0]: int(line.split()[1]) for line in f}
    return (info["MemTotal"] - info["MemAvailable"]) // 1024, info["MemTotal"] // 1024


def main():
    ap = argparse.ArgumentParser(description="Measures speed and memory")
    ap.add_argument("--base-url")
    ap.add_argument("--prompt-tokens", type=int, default=8000)
    ap.add_argument("--gen-tokens", type=int, default=256)
    ap.add_argument("--trials", type=int, default=3)
    args = ap.parse_args()
    base = args.base_url or default_base_url()
    model = call(base, "GET", "/v1/models", timeout=10)[1]["data"][0]["id"]
    print(f"Server: {base}   Model: {model}")

    # Calibrate the prompt length on the server's tokenizer.
    n_words = int(args.prompt_tokens / 1.3)
    for _ in range(4):
        n = stream_chat(base, model, new_prompt(n_words), 1)[2]["prompt_tokens"]
        if abs(n - args.prompt_tokens) <= args.prompt_tokens * 0.005:
            break
        n_words = int(n_words * args.prompt_tokens / n)

    prompt_speeds, gen_speeds = [], []
    for trial in range(1, args.trials + 1):
        first, last, usage = stream_chat(base, model, new_prompt(n_words), args.gen_tokens)
        p, c = usage["prompt_tokens"], usage["completion_tokens"]
        prompt_speeds.append(p / first)
        gen_speeds.append((c - 1) / (last - first))
        print(f"  trial {trial}: prompt {p} tok, first token {first:.1f} s -> {prompt_speeds[-1]:.1f} tok/s; "
              f"{c} tok generated at {gen_speeds[-1]:.1f} tok/s")

    # Two requests at once: short prompts.
    results = []

    def one():
        results.append(stream_chat(base, model, f"Run {uuid.uuid4()}. Count upwards from 1.", args.gen_tokens)[2])
    started = time.monotonic()
    threads = [threading.Thread(target=one) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.monotonic() - started
    total = sum(u["completion_tokens"] for u in results)

    used, all_mb = memory_mb()
    print()
    print(f"Prompt processing:  {statistics.median(prompt_speeds):.1f} tok/s (median, {args.prompt_tokens}-token prompt)")
    print(f"Generation:         {statistics.median(gen_speeds):.1f} tok/s (median, {args.gen_tokens} tokens)")
    print(f"2 requests at once: {total / 2 / wall:.1f} tok/s each, {total / wall:.1f} tok/s total")
    print(f"Memory in use:      {used} of {all_mb} MB (whole machine; the GPU shares this memory)")


if __name__ == "__main__":
    main()
