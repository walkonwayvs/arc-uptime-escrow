#!/usr/bin/env python3
"""Return the unpaid hours of an escrow to its customer, once the term plus
the 24-hour grace period is over. Anyone may trigger it; the money always
goes to the customer.

Usage: refund.py <job-name>            send the refund
       refund.py <job-name> --dry-run  only report whether it can be sent
"""
import sys
import time

from eth_account import Account

from claim import send_tx, selector, view
from common import RPC, load_config, load_key


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    name, dry = sys.argv[1], "--dry-run" in sys.argv
    cfg = load_config()
    job = next((j for j in cfg["jobs"] if j["name"] == name), None)
    if job is None:
        sys.exit(f"no job named {name} in config")

    rpc = RPC(cfg["rpc_url"])
    escrow = job["escrow"]
    stamp = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())
    if view(rpc, escrow, "refunded()", out="bool"):
        print(f"{stamp} {name}: already refunded")
        return
    now_hour = view(rpc, escrow, "currentHour()", out="uint64")
    ready_at = view(rpc, escrow, "endHour()", out="uint64") + view(rpc, escrow, "GRACE_HOURS()", out="uint64")
    if now_hour < ready_at:
        print(f"{stamp} {name}: too early, refund opens at hour {ready_at} (now {now_hour})")
        return
    if dry:
        print(f"{stamp} {name}: refund can be sent now")
        return

    acct = Account.from_key(load_key(cfg))
    ok, tx_hash, fee = send_tx(rpc, cfg, acct, escrow, "0x" + selector("refund()").hex())
    state = "OK" if ok else ("FAILED" if ok is False else "NOT CONFIRMED YET")
    print(f"{stamp} {name}: refund {state}, fee {fee:.6f} USDC, {cfg['explorer']}/tx/{tx_hash}")


if __name__ == "__main__":
    main()
