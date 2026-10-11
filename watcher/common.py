"""Shared helpers for the uptime watcher and the claim script.

Standard library plus eth-account. Talks to Arc over plain JSON-RPC.
"""
import json
import os
import socket
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONFIG_PATH = Path(os.environ.get("UPTIME_CONFIG", HERE / "config.json"))

# Some home networks resolve IPv6 addresses that never answer, which makes
# Python hang on connect. Set FORCE_IPV4=1 to only use IPv4.
if os.environ.get("FORCE_IPV4") == "1":
    _orig_getaddrinfo = socket.getaddrinfo

    def _ipv4_only(host, port, family=0, type=0, proto=0, flags=0):
        return _orig_getaddrinfo(host, port, socket.AF_INET, type, proto, flags)

    socket.getaddrinfo = _ipv4_only


def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)


def load_key(cfg):
    key = Path(cfg["watcher_key_file"]).read_text().strip()
    return key if key.startswith("0x") else "0x" + key


def http_get_json(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": "uptime-escrow-watcher/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


class RPC:
    def __init__(self, url):
        self.url = url
        self._id = 0

    def call(self, method, params=None):
        self._id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params or []}).encode()
        req = urllib.request.Request(self.url, data=body, headers={"Content-Type": "application/json", "User-Agent": "uptime-escrow-watcher/1.0"})
        # Public endpoints rate limit; back off and retry instead of failing the run.
        for wait in (2, 4, 8, 16, 32, None):
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    resp = json.loads(r.read().decode())
                break
            except urllib.error.HTTPError as e:
                if wait is None or e.code not in (429, 500, 502, 503, 504):
                    raise
                time.sleep(wait)
        if "error" in resp:
            raise RuntimeError(f"{method}: {resp['error']}")
        return resp["result"]


def read_log(path):
    p = Path(path)
    if not p.exists():
        return []
    return [json.loads(line) for line in p.read_text().splitlines() if line.strip()]
