"""Helpers shared by the scripts. Standard library only."""

import http.client
import json
import os
import re
import subprocess
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
XAVIER = os.path.dirname(HERE)


def settings():
    """config/settings.env as a dict."""
    values = {}
    with open(os.path.join(XAVIER, "config", "settings.env"), encoding="utf-8") as f:
        for line in f:
            m = re.match(r'([A-Z0-9_]+)=("[^"]*"|\S*)', line)
            if m:
                values[m.group(1)] = m.group(2).strip('"')
    return values


def default_base_url():
    ip = subprocess.check_output(["tailscale", "ip", "-4"], universal_newlines=True).split()[0]
    return f"http://{ip}:{settings()['PORT']}"


def connect(base, timeout=1800):
    u = urllib.parse.urlsplit(base)
    return http.client.HTTPConnection(u.hostname, u.port or 80, timeout=timeout)


def call(base, method, path, body=None, timeout=1800):
    """(status, parsed JSON reply)."""
    conn = connect(base, timeout)
    try:
        data = json.dumps(body).encode("utf-8") if body is not None else None
        conn.request(method, path, body=data, headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        raw = resp.read().decode("utf-8", "replace")
        try:
            return resp.status, json.loads(raw)
        except ValueError:
            return resp.status, raw
    finally:
        conn.close()
