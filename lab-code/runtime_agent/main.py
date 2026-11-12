"""Minimal AgentCore Runtime agent (stdlib only) that stands in for a real agent calling AgentCore Gateway.

Implements the Runtime HTTP contract: GET /ping and POST /invocations on port 8080.
Payload: {"gatewayUrl": "...", "token": "<inbound JWT>", "body": {<MCP JSON-RPC>}, "extraHeaders": {...}}
Returns the IPs the Gateway hostname resolved to (proves private DNS -> Gateway interface endpoint) and the response.
"""
import json
import re
import socket
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GATEWAY_HOST = re.compile(r"^[a-z0-9-]+\.gateway\.bedrock-agentcore\.[a-z0-9-]+\.amazonaws\.com$")


def call_gateway(ev):
    url = ev["gatewayUrl"]
    parsed = urllib.parse.urlparse(url)
    host = parsed.hostname or ""
    # Only call an AgentCore Gateway over HTTPS, so the agent can't be pointed at arbitrary hosts or schemes.
    if parsed.scheme != "https" or not GATEWAY_HOST.match(host):
        return {"caller": "AgentCore Runtime (VPC mode)", "status": None, "error": "gatewayUrl must be an https AgentCore Gateway URL"}
    out = {"caller": "AgentCore Runtime (VPC mode)",
           "resolvedTo": sorted({a[4][0] for a in socket.getaddrinfo(host, 443)})}
    req = urllib.request.Request(url, data=json.dumps(ev["body"]).encode(), method="POST",
                                 headers={"Authorization": "Bearer " + ev["token"], "Content-Type": "application/json",
                                          **ev.get("extraHeaders", {})})
    try:
        with urllib.request.urlopen(req, timeout=50) as r:  # nosec B310 - https Gateway URL checked above
            out.update(status=r.status, body=r.read().decode()[:1500])
    except urllib.error.HTTPError as e:
        out.update(status=e.code, body=e.read().decode()[:500])
    except Exception as e:  # noqa: BLE001 - report any network error back to the caller
        out.update(status=None, error=repr(e))
    return out


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802
        if self.path.startswith("/ping"):
            return self._send(200, {"status": "Healthy"})
        return self._send(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        if not self.path.startswith("/invocations"):
            return self._send(404, {"error": "not found"})
        length = int(self.headers.get("Content-Length") or 0)
        try:
            ev = json.loads(self.rfile.read(length) or b"{}")
            return self._send(200, call_gateway(ev))
        except Exception as e:  # noqa: BLE001
            return self._send(500, {"error": repr(e)})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    # AgentCore Runtime requires the container to listen on port 8080 on all interfaces inside its microVM.
    # The port isn't published: callers reach the agent only through the InvokeAgentRuntime API, which uses IAM.
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()  # nosec B104 - Runtime contract, no published port
