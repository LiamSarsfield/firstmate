"""Fault-injecting HTTPS MITM proxy for live fm-contributions validation.

gh reaches api.github.com through HTTPS_PROXY=http://127.0.0.1:<port>. Each
CONNECT is terminated with a leaf cert signed by a scratch CA (trusted only via
SSL_CERT_FILE in the poll environment). Each request is either answered by an
injected fault from rules.json or forwarded verbatim to the real api.github.com.
Only method, path, scenario and outcome are logged - never headers.
"""
import http.client
import json
import os
import socket
import socketserver
import ssl
import sys
import threading
import time

SCR = sys.argv[1]
RULES = os.path.join(SCR, "rules.json")
LOG = os.path.join(SCR, "proxy.log")
lock = threading.Lock()
counters = {}
current = {"scenario": None}

server_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
server_ctx.load_cert_chain(os.path.join(SCR, "certs", "leaf.pem"), os.path.join(SCR, "certs", "leaf.key"))
server_ctx.set_alpn_protocols(["http/1.1"])
upstream_ctx = ssl.create_default_context()
HOP = {"connection", "keep-alive", "transfer-encoding", "proxy-connection", "proxy-authenticate",
       "proxy-authorization", "te", "trailer", "upgrade", "content-length"}


def log(line):
    with lock:
        with open(LOG, "a") as f:
            f.write("%.3f %s\n" % (time.time(), line))


def pick_rule(method, path):
    try:
        with open(RULES) as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        cfg = {"scenario": "none", "rules": []}
    scenario = cfg.get("scenario", "none")
    with lock:
        if scenario != current["scenario"]:
            current["scenario"] = scenario
            counters.clear()
        for i, rule in enumerate(cfg.get("rules", [])):
            if rule.get("method") and rule["method"] != method:
                continue
            if rule["match"] not in path:
                continue
            times = rule.get("times", -1)
            used = counters.get(i, 0)
            if times >= 0 and used >= times:
                continue
            counters[i] = used + 1
            return scenario, rule
    return scenario, None


def read_request(rf):
    line = rf.readline()
    if not line:
        return None
    method, target, _ = line.decode("latin-1").rstrip("\r\n").split(" ", 2)
    headers = []
    while True:
        h = rf.readline().decode("latin-1").rstrip("\r\n")
        if not h:
            break
        k, v = h.split(":", 1)
        headers.append((k.strip(), v.strip()))
    lower = {k.lower(): v for k, v in headers}
    body = b""
    if "content-length" in lower:
        body = rf.read(int(lower["content-length"]))
    elif lower.get("transfer-encoding", "").lower() == "chunked":
        while True:
            size = int(rf.readline().split(b";")[0], 16)
            if size == 0:
                rf.readline()
                break
            body += rf.read(size)
            rf.readline()
    return method, target, headers, body


def send(conn, status, reason, headers, body):
    out = ["HTTP/1.1 %d %s" % (status, reason)]
    for k, v in headers:
        if k.lower() not in HOP:
            out.append("%s: %s" % (k, v))
    out.append("Content-Length: %d" % len(body))
    out.append("Connection: close")
    conn.sendall(("\r\n".join(out) + "\r\n\r\n").encode("latin-1") + body)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        raw = self.request
        rf = raw.makefile("rb")
        line = rf.readline().decode("latin-1")
        while rf.readline() not in (b"\r\n", b"\n", b""):
            pass
        if not line.startswith("CONNECT "):
            raw.sendall(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
            return
        host = line.split()[1].split(":")[0]
        raw.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        try:
            tls = server_ctx.wrap_socket(raw, server_side=True)
        except (ssl.SSLError, OSError) as e:
            log("tls-handshake-failed host=%s err=%s" % (host, type(e).__name__))
            return
        tf = tls.makefile("rb")
        req = read_request(tf)
        if req is None:
            tls.close()
            return
        method, path, headers, body = req
        scenario, rule = pick_rule(method, path)
        if rule:
            action = rule.get("action", "status")
            if action == "reset":
                log("[%s] %s %s -> injected TCP reset" % (scenario, method, path))
                tls.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\x01\x00\x00\x00\x00\x00\x00\x00")
                tls.close()
                return
            if action == "hang":
                log("[%s] %s %s -> injected hang %ss" % (scenario, method, path, rule.get("seconds", 12)))
                time.sleep(rule.get("seconds", 12))
                tls.close()
                return
            status = rule["status"]
            log("[%s] %s %s -> injected HTTP %d" % (scenario, method, path, status))
            hdrs = [("Content-Type", rule.get("content_type", "application/json; charset=utf-8"))]
            hdrs += [tuple(h) for h in rule.get("headers", [])]
            send(tls, status, rule.get("reason", "Error"), hdrs, rule.get("body", "").encode())
            tls.close()
            return
        up = http.client.HTTPSConnection(host, 443, context=upstream_ctx, timeout=30)
        fwd = [(k, v) for k, v in headers if k.lower() not in ("proxy-connection", "connection")]
        up.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        for k, v in fwd:
            up.putheader(k, v)
        up.endheaders(body if body else None)
        resp = up.getresponse()
        data = resp.read()
        log("[%s] %s %s -> forwarded HTTP %d" % (scenario, method, path, resp.status))
        send(tls, resp.status, resp.reason, resp.getheaders(), data)
        up.close()
        tls.close()


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


srv = Server(("127.0.0.1", 0), Handler)
with open(os.path.join(SCR, "proxy.port"), "w") as f:
    f.write(str(srv.server_address[1]))
log("proxy listening on 127.0.0.1:%d" % srv.server_address[1])
srv.serve_forever()
