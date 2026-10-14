#!/usr/bin/env python3
"""Local HTTPS CONNECT proxy that injects faults into chosen gh connections.

Usage: fault-proxy.py <workdir> <rules.json>

Every CONNECT is numbered from 1. A connection whose number has a rule is
answered locally: the proxy completes TLS with a throwaway CA-signed
api.github.com certificate, reads one request, logs only its method and path,
and sends the rule's response (or holds the connection open for "hang").
Every other connection is a blind TCP tunnel to the real host, so gh talks to
real GitHub end to end. Request headers (and so the token) are never logged.

Writes <workdir>/port, <workdir>/bundle.pem (system roots + lab CA) and appends
one line per connection to <workdir>/proxy.log.
"""
import datetime
import json
import os
import select
import socket
import ssl
import sys
import threading
import time

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

WORK, RULES = sys.argv[1], sys.argv[2]
LOG = os.path.join(WORK, "proxy.log")
lock = threading.Lock()
counter = 0


def log(line):
    with lock:
        with open(LOG, "a") as f:
            f.write(line + "\n")


def make_certs():
    now = datetime.datetime.now(datetime.timezone.utc)
    ca_key = ec.generate_private_key(ec.SECP256R1())
    ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "fm-lab fault proxy CA")])
    ca = (x509.CertificateBuilder().subject_name(ca_name).issuer_name(ca_name)
          .public_key(ca_key.public_key()).serial_number(x509.random_serial_number())
          .not_valid_before(now - datetime.timedelta(days=1))
          .not_valid_after(now + datetime.timedelta(days=1))
          .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
          .add_extension(x509.KeyUsage(digital_signature=True, key_cert_sign=True, crl_sign=True,
                                       content_commitment=False, key_encipherment=False,
                                       data_encipherment=False, key_agreement=False,
                                       encipher_only=False, decipher_only=False), critical=True)
          .sign(ca_key, hashes.SHA256()))
    leaf_key = ec.generate_private_key(ec.SECP256R1())
    leaf = (x509.CertificateBuilder()
            .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "api.github.com")]))
            .issuer_name(ca_name).public_key(leaf_key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=1))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName("api.github.com")]), critical=False)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            .sign(ca_key, hashes.SHA256()))
    pem = serialization.Encoding.PEM
    with open(os.path.join(WORK, "leaf.pem"), "wb") as f:
        f.write(leaf.public_bytes(pem))
    with open(os.path.join(WORK, "leaf.key"), "wb") as f:
        f.write(leaf_key.private_bytes(pem, serialization.PrivateFormat.PKCS8,
                                       serialization.NoEncryption()))
    with open("/etc/ssl/certs/ca-certificates.crt", "rb") as f:
        system = f.read()
    with open(os.path.join(WORK, "bundle.pem"), "wb") as f:
        f.write(system + b"\n" + ca.public_bytes(pem))


def read_head(sock):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
    return data


def tunnel(client, host, port, n):
    upstream = socket.create_connection((host, port), timeout=10)
    client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
    log(f"conn#{n} tunnel {host}:{port}")
    socks = [client, upstream]
    try:
        while True:
            r, _, _ = select.select(socks, [], [], 30)
            if not r:
                return
            for s in r:
                data = s.recv(65536)
                if not data:
                    return
                (upstream if s is client else client).sendall(data)
    finally:
        upstream.close()


def intercept(client, rule, n, ctx):
    client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
    tls = ctx.wrap_socket(client, server_side=True)
    head = read_head(tls)
    request_line = head.split(b"\r\n", 1)[0].decode("latin-1")
    method, path = (request_line.split(" ") + ["", ""])[:2]
    if rule.get("hang"):
        log(f"conn#{n} intercept {method} {path} -> hang")
        time.sleep(30)
        tls.close()
        return
    body = rule.get("body", "").encode()
    status = rule["status"]
    reason = rule.get("reason", "Error")
    log(f"conn#{n} intercept {method} {path} -> {status} {reason}")
    resp = (f"HTTP/1.1 {status} {reason}\r\n"
            f"Content-Type: {rule.get('content_type', 'application/json; charset=utf-8')}\r\n"
            f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode() + body
    tls.sendall(resp)
    tls.close()


def handle(client):
    global counter
    with lock:
        counter += 1
        n = counter
    try:
        head = read_head(client)
        parts = head.split(b"\r\n", 1)[0].decode("latin-1").split(" ")
        if len(parts) < 2 or parts[0] != "CONNECT":
            log(f"conn#{n} refused non-CONNECT")
            return
        host, port = parts[1].rsplit(":", 1)
        with open(RULES) as f:
            rule = json.load(f).get("faults", {}).get(str(n))
        if rule and host == "api.github.com":
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(os.path.join(WORK, "leaf.pem"), os.path.join(WORK, "leaf.key"))
            ctx.set_alpn_protocols(["http/1.1"])
            intercept(client, rule, n, ctx)
        else:
            tunnel(client, host, int(port), n)
    except Exception as e:  # noqa: BLE001 - log and drop the connection
        log(f"conn#{n} error {type(e).__name__}")
    finally:
        client.close()


def main():
    make_certs()
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(64)
    with open(os.path.join(WORK, "port"), "w") as f:
        f.write(str(srv.getsockname()[1]))
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()


main()
