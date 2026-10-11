#!/usr/bin/env python3
"""Submit signed uptime hours to each escrow in one batch per job.

Reads the watcher's logs, keeps hours that were signed, finished, inside the
term and not yet paid onchain, then calls claim(hours, signatures). The
operator is paid; the account sending the transaction only pays the fee.

Usage: claim.py            submit
       claim.py --dry-run  show what would be submitted, send nothing
"""
import json
import sys
import time

from eth_abi import decode, encode
from eth_account import Account
from eth_utils import keccak

from common import HERE, RPC, load_config, load_key, read_log

MAX_PER_TX = 48
GWEI = 10**9
MIN_FEE = 20 * GWEI  # Arc drops transactions under 20 gwei without an error


def selector(sig):
    return keccak(text=sig)[:4]


def view(rpc, to, sig, arg_types=(), args=(), out="uint256"):
    data = selector(sig) + encode(list(arg_types), list(args))
    raw = rpc.call("eth_call", [{"to": to, "data": "0x" + data.hex()}, "latest"])
    return decode([out], bytes.fromhex(raw[2:]))[0]


def paid_cache_path(job):
    return HERE / (job["log"] + ".paid")


def load_paid_cache(job):
    p = paid_cache_path(job)
    return set(json.loads(p.read_text())) if p.exists() else set()


def save_paid_cache(job, hours):
    paid_cache_path(job).write_text(json.dumps(sorted(hours)))


def pending_hours(rpc, job):
    # Hours already confirmed paid are remembered locally, so each run only asks
    # the chain about a handful of new hours instead of the whole log.
    escrow = job["escrow"]
    if view(rpc, escrow, "refunded()", out="bool"):
        return [], "escrow already refunded"
    now_hour = view(rpc, escrow, "currentHour()", out="uint64")
    start = view(rpc, escrow, "startHour()", out="uint64")
    end = view(rpc, escrow, "endHour()", out="uint64")

    known = load_paid_cache(job)
    todo = []
    for e in read_log(HERE / job["log"]):
        h = e["hour"]
        if not e.get("sig") or h < start or h >= end or h >= now_hour or h in known:
            continue
        time.sleep(0.3)
        if view(rpc, escrow, "paid(uint64)", ["uint64"], [h], out="bool"):
            known.add(h)
            continue
        todo.append((h, e["sig"]))
    save_paid_cache(job, known)
    return todo[:MAX_PER_TX], f"term {start}-{end}, chain hour {now_hour}"


def send_claim(rpc, cfg, acct, escrow, batch):
    hours = [h for h, _ in batch]
    sigs = [bytes.fromhex(s[2:]) for _, s in batch]
    data = "0x" + (selector("claim(uint64[],bytes[])") + encode(["uint64[]", "bytes[]"], [hours, sigs])).hex()
    return send_tx(rpc, cfg, acct, escrow, data)


def send_tx(rpc, cfg, acct, escrow, data):
    gas = int(rpc.call("eth_estimateGas", [{"from": acct.address, "to": escrow, "data": data}]), 16)
    price = int(rpc.call("eth_gasPrice"), 16)
    tx = {
        "type": 2,
        "chainId": cfg["chain_id"],
        "nonce": int(rpc.call("eth_getTransactionCount", [acct.address, "pending"]), 16),
        "to": escrow,
        "value": 0,
        "data": data,
        "gas": gas * 5 // 4,
        "maxFeePerGas": max(price * 2, MIN_FEE + GWEI),
        "maxPriorityFeePerGas": GWEI,
    }
    signed = acct.sign_transaction(tx)
    raw = "0x" + bytes(signed.raw_transaction).hex()
    tx_hash = rpc.call("eth_sendRawTransaction", [raw])

    for _ in range(30):
        receipt = rpc.call("eth_getTransactionReceipt", [tx_hash])
        if receipt:
            ok = receipt["status"] == "0x1"
            fee = int(receipt["gasUsed"], 16) * int(receipt["effectiveGasPrice"], 16) / 1e18
            return ok, tx_hash, fee
        time.sleep(2)
    return None, tx_hash, 0.0


def main():
    dry = "--dry-run" in sys.argv
    cfg = load_config()
    rpc = RPC(cfg["rpc_url"])
    acct = Account.from_key(load_key(cfg))

    for job in cfg["jobs"]:
        batch, info = pending_hours(rpc, job)
        stamp = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())
        if not batch:
            print(f"{stamp} {job['name']}: nothing to claim ({info})")
            continue
        hours = [h for h, _ in batch]
        if dry:
            print(f"{stamp} {job['name']}: would claim {len(hours)} hours {hours[0]}..{hours[-1]} ({info})")
            continue
        ok, tx_hash, fee = send_claim(rpc, cfg, acct, job["escrow"], batch)
        if ok:
            save_paid_cache(job, load_paid_cache(job) | set(hours))
        state = "OK" if ok else ("FAILED" if ok is False else "NOT CONFIRMED YET")
        print(f"{stamp} {job['name']}: claimed {len(hours)} hours, {state}, fee {fee:.6f} USDC, "
              f"{cfg['explorer']}/tx/{tx_hash}")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
