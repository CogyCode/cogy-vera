"""Vera: CogyServer's verifier. She checks plans.

HTTP service in front of llama-server on localhost. Standard library only, so
it runs on the system Python 3.8 that ships with JetPack 5.

    GET  /health             service and model status
    POST /verify             {"plan": "...", "diff": "..."} -> verdict JSON
    *    /v1/...             passed through to llama-server (OpenAI API)

The verdict has a fixed shape (config/verdict.schema.json), enforced with
response_format and checked here before it is returned:

    {"analysis": "...", "findings": [{"file", "line", "problem", "fix"}],
     "summary": "...", "verdict": "approve" | "changes"}

Run: python vera.py --config vera.json
"""

import argparse
import http.client
import json
import logging
import logging.handlers
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 4 * 1024 * 1024
log = logging.getLogger("vera")


# --- Verdict checking ---------------------------------------------------------

def validate(value, schema, path="$"):
    """Errors for value against the JSON-schema subset the verdict uses:
    type (object, array, string, integer), enum, properties, required,
    additionalProperties: false, items."""
    errors = []
    kind = schema.get("type")
    if kind == "object":
        if not isinstance(value, dict):
            return [f"{path}: expected an object"]
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing '{key}'")
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in props:
                    errors.append(f"{path}: unexpected '{key}'")
        for key, sub in props.items():
            if key in value:
                errors += validate(value[key], sub, f"{path}.{key}")
    elif kind == "array":
        if not isinstance(value, list):
            return [f"{path}: expected an array"]
        for i, item in enumerate(value):
            errors += validate(item, schema.get("items", {}), f"{path}[{i}]")
    elif kind == "string":
        if not isinstance(value, str):
            return [f"{path}: expected a string"]
    elif kind == "integer":
        if not isinstance(value, int) or isinstance(value, bool):
            return [f"{path}: expected an integer"]
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: must be one of {schema['enum']}")
    return errors


def enforce(verdict):
    """The verdict must follow the findings: any finding means changes."""
    if verdict["findings"] and verdict["verdict"] != "changes":
        verdict["verdict"] = "changes"
        return True
    return False


def build_messages(system_prompt, plan, diff=None):
    content = plan.strip()
    if diff and diff.strip():
        content += "\n\n## Diff\n" + diff.strip()
    return [{"role": "system", "content": system_prompt},
            {"role": "user", "content": content}]


class VerifyError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


# --- llama-server client ------------------------------------------------------

class Upstream:
    def __init__(self, url, timeout):
        u = urllib.parse.urlsplit(url)
        self.host, self.port, self.timeout = u.hostname, u.port or 80, timeout

    def connect(self, timeout=None):
        return http.client.HTTPConnection(self.host, self.port, timeout=timeout or self.timeout)

    def request_json(self, method, path, body=None, timeout=None):
        conn = self.connect(timeout)
        try:
            data = json.dumps(body).encode() if body is not None else None
            conn.request(method, path, body=data, headers={"Content-Type": "application/json"})
            resp = conn.getresponse()
            raw = resp.read()
            try:
                return resp.status, json.loads(raw.decode("utf-8"))
            except ValueError:
                return resp.status, {"error": raw.decode("utf-8", "replace")}
        finally:
            conn.close()


# --- Vera -----------------------------------------------------------------------

class Vera:
    def __init__(self, cfg):
        self.cfg = cfg
        self.upstream = Upstream(cfg["upstream"], cfg.get("timeout", 900))
        with open(cfg["prompt_file"], encoding="utf-8") as f:
            self.system_prompt = f.read().strip()
        with open(cfg["schema_file"], encoding="utf-8") as f:
            self.schema = json.load(f)

    def model_state(self):
        try:
            status, body = self.upstream.request_json("GET", "/health", timeout=5)
        except OSError as e:
            return "down", str(e)
        if status == 200:
            return "ready", None
        if status == 503:
            return "loading", None
        return "down", f"llama-server HTTP {status}"

    def verify(self, plan, diff=None):
        request = {
            "model": self.cfg["model"],
            "messages": build_messages(self.system_prompt, plan, diff),
            "max_tokens": self.cfg.get("max_tokens", 4000),
            "response_format": {"type": "json_schema",
                                "json_schema": {"name": "verdict", "strict": True, "schema": self.schema}},
        }
        attempts = 1 + self.cfg.get("retries", 1)
        problem = None
        usage = {"prompt_tokens": 0, "completion_tokens": 0}
        started = time.monotonic()
        for attempt in range(attempts):
            # Greedy first; a retry samples a little so it can come out differently.
            request["temperature"] = 0 if attempt == 0 else 0.3
            try:
                status, body = self.upstream.request_json("POST", "/v1/chat/completions", request)
            except OSError as e:
                raise VerifyError(502, f"llama-server unreachable: {e}")
            if status != 200:
                error = body.get("error") if isinstance(body, dict) else body
                message = error.get("message", error) if isinstance(error, dict) else error
                if isinstance(error, dict) and error.get("type") == "exceed_context_size_error":
                    raise VerifyError(413, f"plan too long for the model's context: {message}")
                if status == 503:
                    raise VerifyError(503, f"model is still loading: {message}")
                raise VerifyError(502, f"llama-server HTTP {status}: {message}")
            for k in usage:
                usage[k] += body.get("usage", {}).get(k, 0)
            choice = body["choices"][0]
            if choice.get("finish_reason") == "length":
                problem = "reply cut off at max_tokens"
                continue
            try:
                verdict = json.loads(choice["message"]["content"])
            except (TypeError, ValueError) as e:
                problem = f"reply is not JSON: {e}"
                continue
            errors = validate(verdict, self.schema)
            if errors:
                problem = "reply does not match the schema: " + "; ".join(errors)
                continue
            # The schema allows it, but CogyServer would have nothing to act on.
            if verdict["verdict"] == "changes" and not verdict["findings"]:
                problem = "verdict is changes but there are no findings"
                continue
            overridden = enforce(verdict)
            return {
                **verdict,
                "verdict_overridden": overridden,
                "model": self.cfg["model"],
                "seconds": round(time.monotonic() - started, 1),
                "usage": usage,
                "attempts": attempt + 1,
            }
        raise VerifyError(502, f"no valid verdict after {attempts} attempts: {problem}")


# --- HTTP -------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "Vera/1"
    vera = None  # set in main()

    def log_message(self, fmt, *args):
        log.debug("%s %s", self.address_string(), fmt % args)

    def send_json(self, status, obj):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            raise VerifyError(413, f"request body over {MAX_BODY} bytes")
        return self.rfile.read(length) if length else b""

    def do_GET(self):
        if self.path == "/health":
            state, detail = self.vera.model_state()
            self.send_json(200 if state == "ready" else 503,
                           {"service": "vera", "status": state, "model": self.vera.cfg["model"], "detail": detail})
        elif self.path.startswith("/v1/"):
            self.proxy("GET", b"")
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        try:
            body = self.read_body()
        except VerifyError as e:
            return self.send_json(e.status, {"error": e.message})
        if self.path == "/verify":
            self.handle_verify(body)
        elif self.path.startswith("/v1/"):
            self.proxy("POST", body)
        else:
            self.send_json(404, {"error": "not found"})

    def handle_verify(self, body):
        try:
            req = json.loads(body.decode("utf-8") or "{}")
        except ValueError:
            return self.send_json(400, {"error": "body is not JSON"})
        plan = req.get("plan") if isinstance(req, dict) else None
        diff = req.get("diff") if isinstance(req, dict) else None
        if not isinstance(plan, str) or not plan.strip():
            return self.send_json(400, {"error": "'plan' (non-empty string) is required"})
        if diff is not None and not isinstance(diff, str):
            return self.send_json(400, {"error": "'diff' must be a string"})
        try:
            result = self.vera.verify(plan, diff)
        except VerifyError as e:
            log.warning("verify failed (%d): %s", e.status, e.message)
            return self.send_json(e.status, {"error": e.message})
        log.info("verify: %s, %d findings, %.1f s, %d+%d tokens, attempts %d%s",
                 result["verdict"], len(result["findings"]), result["seconds"],
                 result["usage"]["prompt_tokens"], result["usage"]["completion_tokens"],
                 result["attempts"], ", verdict overridden" if result["verdict_overridden"] else "")
        self.send_json(200, result)

    def proxy(self, method, body):
        """Pass a request through to llama-server, streaming the reply."""
        try:
            conn = self.vera.upstream.connect()
            headers = {"Content-Type": self.headers.get("Content-Type", "application/json")}
            conn.request(method, self.path, body=body or None, headers=headers)
            resp = conn.getresponse()
        except OSError as e:
            return self.send_json(502, {"error": f"llama-server unreachable: {e}"})
        try:
            self.send_response(resp.status)
            for name in ("Content-Type", "Cache-Control"):
                if resp.getheader(name):
                    self.send_header(name, resp.getheader(name))
            self.send_header("Connection", "close")
            self.end_headers()
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            conn.close()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--config", required=True, help="vera.json written by install.sh")
    args = ap.parse_args(argv)
    with open(args.config, encoding="utf-8") as f:
        cfg = json.load(f)

    # One log: the rotating file when configured (the service), else the console.
    if cfg.get("log_file"):
        handlers = [logging.handlers.RotatingFileHandler(cfg["log_file"], maxBytes=5_000_000,
                                                         backupCount=3, encoding="utf-8")]
    else:
        handlers = [logging.StreamHandler(sys.stdout)]
    logging.basicConfig(level=logging.INFO, handlers=handlers,
                        format="%(asctime)s %(levelname)s %(message)s")

    Handler.vera = Vera(cfg)
    server = ThreadingHTTPServer((cfg["bind"], cfg["port"]), Handler)
    server.daemon_threads = True
    log.info("Vera listening on http://%s:%d, model %s via %s",
             cfg["bind"], cfg["port"], cfg["model"], cfg["upstream"])
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
