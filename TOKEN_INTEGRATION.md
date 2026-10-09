# $QUAK token integration

Quakemeter **does not create, deploy or mint any token.** The project token ($QUAK) will be launched separately on
a launchpad. The protocol is fully functional without it, and every token feature stays off until governance wires
the token in, exactly once.

## What the token does (once set)

| Feature | Contract | Behaviour |
|---|---|---|
| Fee sharing | `ProjectTokenHooks` + `FeeCollector` | `FeeCollector.distribute()` sends `stakerBps` (default 20%) of trading fees, in USDG, to stakers pro-rata. Claim with `ProjectTokenHooks.claim()`. |
| Fee-discount tiers | `ProjectTokenHooks.feeDiscountBps` → `FeeCollector.feeDiscountBps` → `FuturesMarket._fee` | Active stake ≥ 1,000 / 10,000 / 100,000 $QUAK → 10% / 20% / 30% off trading fees (whole-token thresholds, scaled by the token's `decimals()`; editable via Timelock `setTiers`, max 4 tiers, max 50% discount). |
| Unstake cooldown | `ProjectTokenHooks` | `requestUnstake` stops rewards and discounts immediately; `withdrawUnstaked` after 7 days (Timelock-tunable, ≤ 30 days). Stops stake → trade → unstake fee gaming. |

## Before the token is set (default)

* `ProjectTokenHooks.isActive()` is `false`; `stake()` reverts with `TokenNotSet()`.
* `feeDiscountBps(anyone) == 0`, so everyone pays the full fee.
* `FeeCollector.distribute()` routes the staker share to the LP vault instead.
* The frontend hides every token feature when `NEXT_PUBLIC_PROJECT_TOKEN` is empty.

## Wiring the token (one time, via the 48 h Timelock)

`setProjectToken(address)` is callable only by `DEFAULT_ADMIN_ROLE` (the Timelock), only once
(`AlreadySet()` afterwards), and rejects the zero address, EOAs and the stablecoin itself. It reads the token's
`decimals()` to scale the tier thresholds.

```bash
# 1) schedule (Timelock proposer = the deployer account unless TIMELOCK_PROPOSER was set at deploy)
cd contracts
forge script script/Ops.s.sol:SetProjectToken --sig "schedule(address)" <QUAK_TOKEN_ADDRESS> \
  --rpc-url https://rpc.mainnet.chain.robinhood.com --account quakemeter-deployer --sender <DEPLOYER_ADDRESS> --broadcast

# 2) at least 48 hours later
forge script script/Ops.s.sol:SetProjectToken --sig "execute(address)" <QUAK_TOKEN_ADDRESS> \
  --rpc-url https://rpc.mainnet.chain.robinhood.com --account quakemeter-deployer --sender <DEPLOYER_ADDRESS> --broadcast
```

Then set `NEXT_PUBLIC_PROJECT_TOKEN=<QUAK_TOKEN_ADDRESS>` in the Vercel project and redeploy the frontend. The Stake
page appears; until step 2 executes, it shows "token not yet activated by governance".

## Token requirements

A plain ERC-20 works. Fee-on-transfer tokens are handled (stake credits the received amount); rebasing tokens are
**not** supported (stake accounting would drift). The token must not be USDG.

## Testing

Tests use a mock ERC-20 (`contracts/test/mocks/Mocks.sol`, `MockERC20`) as a stand-in. It is never deployed by any
script. See `contracts/test/unit/Money.t.sol` (`FeesAndTokenTest`).
