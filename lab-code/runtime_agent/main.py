"""Minimal AgentCore Runtime agent (stdlib only) that stands in for a real agent calling AgentCore Gateway.

Implements the Runtime HTTP contract: GET /ping and POST /invocations on port 8080.
Payload: {"gatewayUrl": "...", "token": "<inbound JWT>", "body": {<MCP JSON-RPC>}, "extraHeaders": {...}}
Returns the IPs the Gateway hostname resolved to (proves private DNS -> Gateway interface endpoint) and the response.
"""
import json
import posixpath
import re
import socket
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CALLER = "AgentCore Runtime (VPC mode)"
# Anchored, with bounded labels, so matching stays linear in the hostname length (DNS labels are at most 63 characters).
GATEWAY_HOST = re.compile(r"^[a-z0-9-]{1,63}\.gateway\.bedrock-agentcore\.[a-z0-9-]{1,63}\.amazonaws\.com\Z")
# Callers may add test headers (X-...), but not override Host, Authorization, Content-Type or Content-Length.
EXTRA_HEADER = re.compile(r"X-[A-Za-z0-9-]{1,64}")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Don't follow redirects, so a 3xx can't send the request to a host that wasn't validated."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect())


def _validated_gateway_url(raw_url):
    """Return (url, host) rebuilt from the parts of raw_url, which must be an https AgentCore Gateway URL."""
    if not isinstance(raw_url, str):
        raise TypeError("gatewayUrl must be a string")
    parsed = urllib.parse.urlparse(raw_url)
    host = parsed.hostname or ""
    if parsed.scheme != "https" or len(host) > 253 or not GATEWAY_HOST.match(host):
        raise ValueError("gatewayUrl must be an https AgentCore Gateway URL")
    if parsed.username or parsed.password:
        raise ValueError("gatewayUrl must not include credentials")
    if parsed.params or parsed.query or parsed.fragment:
        raise ValueError("gatewayUrl must not include params, query or fragment")
    if parsed.port not in (None, 443):
        raise ValueError("gatewayUrl must use the default https port")
    path = "/" + posixpath.normpath(parsed.path or "/").lstrip("/")
    return urllib.parse.urlunparse(("https", host, path, "", "", "")), host


def _validated_extra_headers(headers):
    if not isinstance(headers, dict) or not all(isinstance(k, str) and EXTRA_HEADER.fullmatch(k) and isinstance(v, str)
                                                for k, v in headers.items()):
        raise ValueError("extraHeaders must map X-... header names to string values")
    return headers


def call_gateway(ev):
    try:
        url, host = _validated_gateway_url(ev["gatewayUrl"])
        extra = _validated_extra_headers(ev.get("extraHeaders", {}))
    except (KeyError, TypeError, ValueError) as e:
        return {"caller": CALLER, "status": None, "error": str(e)}
    out = {"caller": CALLER, "resolvedTo": sorted({a[4][0] for a in socket.getaddrinfo(host, 443)})}
    req = urllib.request.Request(url, data=json.dumps(ev["body"]).encode(), method="POST",
                                 headers={**extra, "Authorization": "Bearer " + ev["token"], "Content-Type": "application/json"})
    try:
        with _OPENER.open(req, timeout=50) as r:  # nosec B310 - URL rebuilt from a validated https Gateway host
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
