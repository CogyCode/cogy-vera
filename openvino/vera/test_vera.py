"""Unit tests for vera.py against a fake model server. Standard library only.

    python -m unittest discover -s openvino/vera -v
"""

import http.client
import json
import os
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import vera

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_DIR = os.path.join(HERE, "..", "config")
MODEL = "test/model"


def verdict(findings, decision, analysis="checked"):
    return {"analysis": analysis, "findings": findings, "summary": "s", "verdict": decision}


FINDING = {"file": "setup.sh", "line": 3, "problem": "rm -rf /$CACHE_DIR  # wipe", "fix": "rm -rf \"/${CACHE_DIR:?}\""}


class FakeModelServer:
    """Answers /v3/chat/completions with queued replies; records requests."""

    def __init__(self):
        self.replies = []
        self.requests = []
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def reply(self, status, obj):
                data = json.dumps(obj).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                if self.path == "/v1/config":
                    self.reply(200, {MODEL: {"model_version_status": [{"state": "AVAILABLE"}]}})
                elif self.path == "/v3/models":
                    self.reply(200, {"data": [{"id": MODEL}]})
                else:
                    self.reply(404, {"error": "nope"})

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                outer.requests.append(body)
                if body.get("stream"):
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    for word in ("a", "b"):
                        self.wfile.write(f"data: {json.dumps({'choices': [{'delta': {'content': word}}]})}\n\n".encode())
                    self.wfile.write(b"data: [DONE]\n\n")
                    return
                status, obj = outer.replies.pop(0)
                self.reply(status, obj)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def queue_content(self, content, finish="stop"):
        self.replies.append((200, {"choices": [{"message": {"content": content}, "finish_reason": finish}],
                                   "usage": {"prompt_tokens": 10, "completion_tokens": 5}}))

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class TestValidate(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(CONFIG_DIR, "verdict.schema.json"), encoding="utf-8") as f:
            self.schema = json.load(f)

    def test_valid(self):
        self.assertEqual(vera.validate(verdict([FINDING], "changes"), self.schema), [])
        self.assertEqual(vera.validate(verdict([], "approve"), self.schema), [])

    def test_errors(self):
        v = verdict([dict(FINDING, line="3")], "maybe")
        v["extra"] = 1
        del v["summary"]
        errors = " | ".join(vera.validate(v, self.schema))
        for expected in ("missing 'summary'", "unexpected 'extra'", "line: expected an integer", "must be one of"):
            self.assertIn(expected, errors)

    def test_bool_is_not_integer(self):
        self.assertTrue(vera.validate(verdict([dict(FINDING, line=True)], "changes"), self.schema))

    def test_enforce(self):
        v = verdict([FINDING], "approve")
        self.assertTrue(vera.enforce(v))
        self.assertEqual(v["verdict"], "changes")
        v = verdict([], "approve")
        self.assertFalse(vera.enforce(v))
        self.assertEqual(v["verdict"], "approve")

    def test_build_messages(self):
        m = vera.build_messages("sys", " # Plan #42 ", "+#!/bin/bash")
        self.assertEqual(m[0], {"role": "system", "content": "sys"})
        self.assertEqual(m[1]["content"], "# Plan #42\n\n## Diff\n+#!/bin/bash")
        self.assertEqual(vera.build_messages("sys", "p", "  ")[1]["content"], "p")


class TestService(unittest.TestCase):
    def setUp(self):
        self.fake = FakeModelServer()
        cfg = {"upstream": f"http://127.0.0.1:{self.fake.port}", "model": MODEL, "retries": 1,
               "prompt_file": os.path.join(CONFIG_DIR, "review-prompt.txt"),
               "schema_file": os.path.join(CONFIG_DIR, "verdict.schema.json")}
        vera.Handler.vera = vera.Vera(cfg)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), vera.Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.port = self.httpd.server_address[1]

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.fake.close()

    def call(self, method, path, body=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        data = body if isinstance(body, bytes) else (json.dumps(body).encode() if body is not None else None)
        conn.request(method, path, body=data, headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        raw = resp.read().decode()
        conn.close()
        return resp.status, raw

    def verify(self, body):
        status, raw = self.call("POST", "/verify", body)
        return status, json.loads(raw)

    def test_verify_returns_verdict(self):
        self.fake.queue_content(json.dumps(verdict([FINDING], "changes")))
        status, r = self.verify({"plan": "# Plan #42", "diff": "+rm -rf /$CACHE_DIR"})
        self.assertEqual(status, 200)
        self.assertEqual(r["verdict"], "changes")
        self.assertEqual(r["findings"], [FINDING])
        self.assertFalse(r["verdict_overridden"])
        sent = self.fake.requests[0]
        self.assertEqual(sent["model"], MODEL)
        self.assertEqual(sent["temperature"], 0)
        self.assertEqual(sent["response_format"]["type"], "json_schema")
        self.assertIn("## Diff\n+rm -rf /$CACHE_DIR", sent["messages"][1]["content"])

    def test_approve_with_findings_becomes_changes(self):
        self.fake.queue_content(json.dumps(verdict([FINDING], "approve")))
        status, r = self.verify({"plan": "p"})
        self.assertEqual((status, r["verdict"], r["verdict_overridden"]), (200, "changes", True))

    def test_retry_after_bad_reply(self):
        self.fake.queue_content("{not json")
        self.fake.queue_content(json.dumps(verdict([], "approve")))
        status, r = self.verify({"plan": "p"})
        self.assertEqual((status, r["verdict"], r["attempts"]), (200, "approve", 2))
        self.assertEqual(self.fake.requests[1]["temperature"], 0.3)
        self.assertEqual(r["usage"]["completion_tokens"], 10)

    def test_gives_up(self):
        self.fake.queue_content("{}", finish="length")
        self.fake.queue_content("{}", finish="length")
        status, r = self.verify({"plan": "p"})
        self.assertEqual(status, 502)
        self.assertIn("cut off", r["error"])

    def test_context_too_long(self):
        self.fake.replies.append((400, {"error": "Number of prompt tokens: 40000 exceeds model max length: 32768"}))
        status, r = self.verify({"plan": "p"})
        self.assertEqual(status, 413)

    def test_bad_input(self):
        self.assertEqual(self.verify({"diff": "x"})[0], 400)
        self.assertEqual(self.verify({"plan": "  "})[0], 400)
        self.assertEqual(self.verify({"plan": "p", "diff": 3})[0], 400)
        self.assertEqual(self.call("POST", "/verify", b"{oops")[0], 400)

    def test_health_and_404(self):
        status, raw = self.call("GET", "/health")
        self.assertEqual((status, json.loads(raw)["status"]), (200, "ready"))
        self.assertEqual(self.call("GET", "/nope")[0], 404)

    def test_passthrough(self):
        status, raw = self.call("GET", "/v3/models")
        self.assertEqual((status, json.loads(raw)["data"][0]["id"]), (200, MODEL))
        status, raw = self.call("POST", "/v3/chat/completions", {"model": MODEL, "stream": True, "messages": []})
        self.assertEqual(status, 200)
        self.assertIn("data: [DONE]", raw)
        self.assertEqual(raw.count("data: "), 3)


if __name__ == "__main__":
    unittest.main()
