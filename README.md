# Arc Uptime Escrow

**Pay node operators only for the hours they were actually up. Settled hourly in USDC on Arc.**

When you rent a node, an RPC endpoint or a server today, you pay up front and hope it stays up. If it goes down, you open a ticket and argue about a credit. This flips that around:

1. The customer locks USDC in a contract and sets an hourly rate.
2. A watcher checks the service every hour. If it was healthy, the watcher signs a short note: "this service was up during hour N".
3. The operator gets paid for every hour that has a signed note. Hours nobody signed go back to the customer when the term ends.

No invoices, no tickets, no disputes about what happened. The chain shows exactly which hours were paid.

## Live on Arc mainnet

| | |
|---|---|
| Main escrow | [`0x3046e96dD3eD125c673145b461E2B3f74b022EB4`](https://explorer.arc.io/address/0x3046e96dD3eD125c673145b461E2B3f74b022EB4) |
| What it pays for | Uptime of an Arc RPC endpoint, checked every hour |
| Rate | 0.05 USDC per hour |
| Term | Oct 10 06:00 UTC to Oct 22 00:00 UTC (282 hours, 14.10 USDC locked) |
| Down-hour demo | [`0xc26f207Efb199Af63353e6Ae4B0d82Cc8812AE15`](https://explorer.arc.io/address/0xc26f207Efb199Af63353e6Ae4B0d82Cc8812AE15) |
| Source | Verified on the Arc explorer and an exact match on [Sourcify](https://sourcify.dev) |

Payouts go out every 6 hours in one batch. Open the main escrow on the explorer and every paid hour shows up as an `HourPaid` event.

### Results so far

- **First day (Oct 10):** while I tested the watcher against a validator on another network, the escrow watched 18 hours, paid 16 and held back 2. Both misses were real, not staged: one hour the validator fell to 98.9% agreement, just under the bar, and one hour its health data was incomplete, so the watcher refused to sign.
- **From Oct 11:** the same escrow pays for the uptime of an Arc RPC endpoint, so both the service and the money are on Arc. The contract didn't change: it only checks the watcher's signatures, so pointing it at a different service is a watcher setting.
- **Fees:** each 6-hour payout cost about 0.004 to 0.005 USDC, roughly 0.1 cent per paid hour, about 2% of the 5 cent rate.

The second escrow shows a clean down hour on purpose. It watches a small test page that was switched off for one hour (Oct 10, 08:00 to 09:00 UTC). That hour has no signed note, so it was never paid: 3 of its 4 hours paid out, and the unpaid 0.05 USDC goes back to the customer after the term plus a 24 hour grace period.

## Why Arc

- **Gas is paid in USDC.** Paying an operator a few cents an hour only makes sense if the fee to do it is small and predictable. On Arc it is a fixed fraction of a cent in dollars, not a volatile gas token. Batching 6 hours costs about 0.1 cent per hour paid.
- **Finality in under a second.** Once an hour is paid, it is final. No waiting on confirmations.
- **USDC is native.** The escrow holds the chain's own USDC balance, so there is no token approval step for the customer. Deposit and deploy are one transaction.

## What it watches

Every app on Arc reaches the chain through an RPC endpoint, and Arc's docs list several providers that sell that access. That's exactly the kind of service this is built to bill. In the live demo the watched endpoint is Arc's public RPC, standing in for a paid provider.

Near the end of every hour the watcher asks the endpoint for its chain ID and latest block. The hour counts as up when:

- the endpoint answers, on chain 5042,
- it answers within 5 seconds, and
- Arc's block number has moved since the last check, so it isn't serving stale data.

Anything else (no answer, wrong chain, too slow, stuck block number) is logged as down and never signed. When in doubt, the watcher fails toward the customer.

The watcher also supports two other checks: any URL that should answer with HTTP 200 (the down-hour demo uses this), and a validator health check against a public uptime service (used on day one).

## How the contract keeps everyone honest

- A signed note only works for **this contract on this chain**. Signatures follow EIP-712 and include the chain ID and the contract address, so a note can't be replayed on another escrow or another network.
- **Each hour pays once.** Paying the same hour twice reverts, even inside one batch.
- **Only finished hours inside the term** can be paid.
- **Anyone can submit** signed hours, but the money always goes to the operator. Whoever submits only pays the fee.
- **The customer can't pull money early.** The refund only opens 24 hours after the term ends, which gives time to submit the last signed hours. After that, all unpaid hours go back to the customer in one transaction.

## Honest limits

The watcher is the one thing both sides have to trust. In this demo it checks from one place with a single signing key, so a network problem on the watcher's side could cost the operator an hour. Next steps I'd build:

- **Several watchers, k-of-n.** Pay an hour only when, say, 2 of 3 independent watchers in different places signed it.
- **Watchers with public reputation.** Register watchers as agents through ERC-8004, which is already live on Arc mainnet, so their track record is onchain.
- **Recurring jobs on top of ERC-8183.** ERC-8183 escrows a single job with one evaluator. Uptime is the recurring version: pay per verified period, for as long as the service runs.

## Tests

22 tests, including a fuzz test that checks paid plus refunded always equals the deposit.

```
arc-forge test --network arc
```

Covered: a signed hour pays the operator, anyone can submit, batch payouts, unsigned hours, the wrong signer, a signature for a different hour, a signature from a different contract, the same hour twice (in two calls and in one batch), hours before and after the term, unfinished hours, refund before the term ends, refund during the grace period, refund amount, and no claims after a refund.

The watcher and payout scripts were also run end to end on a local Arc chain (`arc-anvil --network arc`), covering healthy hours, a stuck ledger, low agreement, incomplete data, an unreachable service, payouts, and the refund.

## Run your own

You need [Arc Foundry](https://docs.arc.io/arc/tutorials/install-arc-foundry.md) and some USDC on Arc.

**Deploy and fund** (the customer does this, in one transaction). Hours are UTC hour numbers, `unix time / 3600`. The deposit must equal rate × hours. Native USDC on Arc uses 18 decimals, so 0.05 USDC is `50000000000000000`.

```
arc-forge create src/UptimeEscrow.sol:UptimeEscrow \
  --rpc-url https://rpc.mainnet.arc.io --account <customer> --broadcast \
  --gas-price 30gwei --priority-gas-price 1gwei \
  --value <rate × hours> \
  --constructor-args <operator> <watcher> <rate per hour> <start hour> <end hour>
```

Arc drops transactions priced under 20 gwei without an error, so always set the gas price.

**Run the watcher** (Python 3.10+):

```
cd watcher
python3 -m venv venv && venv/bin/pip install eth-account
cp config.example.json config.json   # add your escrow address and key file path
```

Then schedule it:

```
58 * * * *         cd /path/to/watcher && venv/bin/python watcher.py >> logs/watcher.out 2>&1
10 0,6,12,18 * * * cd /path/to/watcher && venv/bin/python claim.py   >> logs/claim.out 2>&1
```

`watcher.py` checks each job near the end of the hour and signs healthy hours. `claim.py` submits all signed, unpaid hours in one batch (`--dry-run` shows what it would send). `refund.py <job>` returns unpaid hours to the customer once the term and grace period are over.

## Files

```
src/UptimeEscrow.sol         the escrow contract
test/UptimeEscrow.t.sol      contract tests
watcher/watcher.py           hourly health check and signing
watcher/claim.py             batch payout of signed hours
watcher/refund.py            refund of unpaid hours after the term
watcher/common.py            shared helpers (config, JSON-RPC)
watcher/config.example.json  example settings
```

## License

MIT
