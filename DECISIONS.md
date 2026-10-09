# Decisions log

One line each: what was decided and why.

## Chain & data
- **Chain ID 4663, RPC `rpc.mainnet.chain.robinhood.com`, Blockscout explorer/verifier, ETH gas.** Read from docs.robinhood.com/chain and checked live (`eth_chainId`).
- **USDG (`0x5fc5…d168`, 6 decimals) as margin/LP collateral.** It is the stablecoin listed on the official token-contracts page; no USDC is listed.
- **Basket = AAPL, AMZN, GOOGL, META, MSFT, NVDA, TSLA.** These are the largest-cap stock tokens with live Chainlink feeds. Canonical addresses come from the on-chain asset registry that backs the docs table (`api.robinhood.com/rhj/assets`). Symbols, decimals and feed descriptions are verified in fork tests.
- **Chainlink feed addresses from Chainlink's directory JSON for `robinhood-mainnet`.** It's the source Robinhood's oracle docs link to, and each feed was confirmed with `description()`/`latestRoundData()`.
- **Sequencer uptime feed left unset (gap documented).** Chainlink doesn't list one for Robinhood Chain yet. The adapter supports it, and the Timelock can set it later.
- **Feed staleness 25 h (heartbeat 24 h + 1 h).** Feeds update on 0.5% deviation or a 24 h heartbeat; a tighter bound would reject valid quiet prices.
- **`config/chains.json` is the single source of truth.** `chains.ts` types it for TS; Foundry reads the JSON with `vm.readFile`, so addresses can't drift between frontend and deploy.

## Index
- **Equal-weight gross return, rebalanced each sample, log of the mean ratio.** It's the standard equal-weight index return and is robust to one asset being missing.
- **Zero-mean realized variance.** Market convention for realized-vol indices and variance swaps; avoids the mean-estimation noise of a short window.
- **147-return window (21 trading days × 7 slots ≈ 30 calendar days).** Matches the "30-day" horizon of vol indices.
- **1764 periods/year, overnight counted as one period.** 6 intraday hours + 1 overnight = 7 periods per day, so full-day variance is preserved.
- **Periods per return come from the clock (missed hours count).** Keeps the estimator unbiased when the keeper misses samples.
- **±25% per-sample clamp.** Bounds the damage from any single bad print but still admits real earnings gaps (rarely > 25% for these names).
- **Quorum 6 of 7, carry-forward for missing assets.** Tolerates one stale or paused feed (corporate actions pause feeds) without biasing variance.
- **Re-base after gaps > 10 days.** A long outage shouldn't create one giant return.
- **On-chain DST + Timelock-managed holiday/early-close calendar, 2026–2027 seeded.** Holidays are known a year ahead; the 48 h delay is harmless for them.
- **Rounds stored with cumulative Σr² and Σperiods.** Gives O(1) settlement and variance-swap reads with no loops.
- **Permissionless `sample()` with one sample per slot.** Liveness doesn't depend on our keeper; dedup removes timing games within a slot.

## Futures
- **1 contract = $1 per QVIX point.** Easy mental model; fractional sizes are allowed (18 decimals).
- **Monthly expiry = third Friday 16:00 ET; first expiry ≥ 45 days after deploy; 3 expiries deployed.** Standard monthly cycle, leaving time for the 30-day warm-up.
- **Settlement = average of the last 7 prints ≤ expiry, capped at 400.** A one-day average makes the settlement print hard to manipulate.
- **Constant-product vAMM, 1M contracts depth (configurable before open), opened at spot QVIX.** Simple, well understood, no external liquidity needed.
- **15-minute EMA mark for margin, 10% per-trade impact cap, price bounds [1, 500].** Stops single-block mark manipulation and runaway prices.
- **Funding toward spot QVIX: premium (EMA − index) paid over 1 day, clamped ±10%/day, paused if the index is > 4 days old.** As specified, with guardrails.
- **Isolated margin per position, IM 20% (5×), MM 10%.** As specified; the 10% buffer suits a vol product.
- **Partial (50%) liquidation above $10k notional, 2% penalty split 50/50 liquidator/insurance.** Dampens cascades while still paying liquidators.
- **Permissionless liquidations through a `Liquidator` contract.** One entry point (plus bounded batch) while markets only trust that contract.
- **Trader profit capped at vault + insurance capacity per tx.** Payouts never revert; the shortfall case is explicit, not a stuck position.
- **Trading opens permissionlessly (`openTrading`) once QVIX is ready.** No admin step is needed when the 30-day warm-up completes.
- **Emergency settlement only by Timelock and only 7 days after expiry.** A last resort if the index is stuck; normal settlement is fully permissionless.
- **New monthly markets via `Ops.s.sol:NewExpiry` (deploy, then Timelock registration).** Keeps listings behind the 48 h delay.

## Vault, fees, insurance
- **ERC-4626 vault with virtual-share offset 6.** Neutralizes first-depositor inflation attacks.
- **Open trader profit counted as a liability; open trader losses not counted.** Conservative share price, so LPs can't exit ahead of realized losses.
- **Withdrawals capped by reserve = 50% of net open notional per market.** Keeps counterparty capital in place while risk is open.
- **24 h deposit lock, no transfer of locked shares, no third-party deposits.** Stops just-in-time LPing around fee drops and lock griefing.
- **OI caps: net ≤ 20%, per-side ≤ 50% of vault assets (per market).** Bounds vault exposure to a 5× QVIX move.
- **Fees 0.10% of notional; split LP 50 / insurance 20 / stakers 20 / treasury 10; staker share → LPs while the token is unset.** Pays the counterparty first and funds the insurance fund.
- **Treasury defaults to the Timelock.** No EOA receives protocol revenue unless configured (`TREASURY_ADDRESS`).

## Variance swaps
- **Fully collateralized P2P offers; long posts N·K, short posts N·(6.25K − K) (cap 2.5× strike vol).** Standard variance-swap cap keeps short collateral finite.
- **Start = first round ≥ fill time, end = last round ≤ maturity (hinted, verified).** Only returns fully inside the period count, so nobody can trade on an intra-hour move that's already happened.
- **Pull payments + refund after 30-day grace.** A frozen USDG account can't block the counterparty; there's an exit if the index is unavailable.
- **No protocol fee on variance swaps.** It's an optional module; adding a fee later is a contract upgrade decision.

## Governance & security
- **OpenZeppelin TimelockController with a 48 h minimum delay and no admin.** As specified; role changes also go through the delay.
- **Guardian can pause, only the Timelock can unpause.** A fast brake that can't be abused to toggle markets.
- **Deployer renounces every role in the same script.** No privileged EOA remains (asserted in tests).
- **ComplianceRegistry allowlist, off by default; gates entries only (deposit, open, LP deposit, swaps), never exits.** As specified, and gating can never trap funds.
- **No upgradeability (no proxies).** Smaller trust surface; changes ship as new contracts behind the Timelock.
- **Solidity 0.8.28, optimizer 200 runs, no via-IR.** Keeps `forge coverage` working and contract sizes under 24 KB.

## Tooling
- **Keeper signs through `forge script --account quakemeter-keeper`.** Uses the Foundry keystore; on this machine `cast.exe` was blocked by Windows Application Control, while forge works.
- **Fork tests default to the latest block.** The public RPC isn't an archive node (historical state unavailable); set `FORK_BLOCK` with an archive RPC to pin one.
- **Local fork runs on port 8555 with chain id 31337.** Ports 8545/8546 were occupied by other local nodes; 31337 keeps fork deployments from being mistaken for mainnet ones.
- **TS reference runs with Node 24 native type-stripping.** No build step is needed for the FFI test.
