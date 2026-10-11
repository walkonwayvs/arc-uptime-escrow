#!/usr/bin/env python3
"""Hourly uptime watcher.

Run near the end of each UTC hour (cron at minute 58). For each job in
config.json it checks whether the service was healthy this hour. If it was,
it signs "this service was up during hour N" for that job's escrow and appends
the result to the job's log. Down hours are logged too, unsigned, so the
operator never gets paid for them.

Checks:
  vhs   Post Fiat's own validator health service. Healthy means the 1-hour
        agreement score is at or above min_agreement, the hour's data is
        complete, and the validator's ledger index moved since the last check.
  http  A plain URL. Healthy means it answers with HTTP 200.
  arc_rpc  An Arc RPC endpoint. Healthy means it answers on the expected chain
        within max_ms (default 5000) and the block number moved since the last
        check.
"""
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from eth_account import Account

from common import HERE, RPC, http_get_json, load_config, load_key, read_log


def check_vhs(job, last):
    data = http_get_json(job["vhs_url"].format(pubkey=job["pubkey"]))
    a1h = data["agreement_1h"]
    score = float(a1h["score"])
    index = int(data["current_index"])
    detail = {"score": a1h["score"], "missed": a1h["missed"], "total": a1h["total"], "index": index}
    if a1h.get("incomplete"):
        return False, "1h data incomplete", detail
    if score < job["min_agreement"]:
        return False, f"agreement {score} below {job['min_agreement']}", detail
    if last and last.get("index") is not None and index <= last["index"]:
        return False, "ledger index did not move", detail
    return True, "ok", detail


def check_http(job, last):
    try:
        req = urllib.request.Request(job["url"], headers={"User-Agent": "uptime-escrow-watcher/1.0"})
        with urllib.request.urlopen(req, timeout=15) as r:
            code = r.status
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception as e:
        return False, f"unreachable: {type(e).__name__}", {}
    return code == 200, f"http {code}", {"http": code}


def check_arc_rpc(job, last):
    rpc = RPC(job["url"])
    t0 = time.time()
    chain = int(rpc.call("eth_chainId"), 16)
    block = int(rpc.call("eth_blockNumber"), 16)
    ms = int((time.time() - t0) * 1000)
    detail = {"block": block, "ms": ms}
    if chain != job["chain_id"]:
        return False, f"wrong chain {chain}", detail
    if ms > job.get("max_ms", 5000):
        return False, f"too slow ({ms} ms)", detail
    if last and last.get("block") is not None and block <= last["block"]:
        return False, "block number did not move", detail
    return True, "ok", detail


CHECKS = {"vhs": check_vhs, "http": check_http, "arc_rpc": check_arc_rpc}


def sign_hour(key, chain_id, escrow, hour):
    signed = Account.sign_typed_data(
        key,
        domain_data={"name": "UptimeEscrow", "version": "1", "chainId": chain_id, "verifyingContract": escrow},
        message_types={"UptimeHour": [{"name": "hour", "type": "uint64"}]},
        message_data={"hour": hour},
    )
    return "0x" + bytes(signed.signature).hex()


def run_job(cfg, key, job, hour):
    log_path = HERE / job["log"]
    entries = read_log(log_path)
    if any(e["hour"] == hour for e in entries):
        return f"{job['name']}: hour {hour} already logged, skipping"
    last = entries[-1] if entries else None

    up, reason, detail = False, "check failed", {}
    for attempt in range(3):
        try:
            up, reason, detail = CHECKS[job["check"]](job, last)
            break
        except Exception as e:
            reason = f"check error: {type(e).__name__}: {e}"
            if attempt < 2:
                time.sleep(20)

    entry = {"hour": hour, "checked_at": int(time.time()), "up": up, "reason": reason, **detail}
    if up:
        entry["sig"] = sign_hour(key, cfg["chain_id"], job["escrow"], hour)

    log_path.parent.mkdir(parents=True, exist_ok=True)
    with open(log_path, "a") as f:
        f.write(json.dumps(entry) + "\n")
    return f"{job['name']}: hour {hour} {'UP (signed)' if up else 'DOWN'} - {reason}"


def main():
    cfg = load_config()
    key = load_key(cfg)
    hour = int(time.time()) // 3600
    for job in cfg["jobs"]:
        print(time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()), run_job(cfg, key, job, hour))
        sys.stdout.flush()


if __name__ == "__main__":
    main()
