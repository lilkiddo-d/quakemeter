# Quakemeter threat model

Scope: everything in `contracts/src` as deployed by `script/Deploy.s.sol`. Assets at risk: trader margin
(MarginAccount), LP capital (LPVault), insurance fund, variance-swap escrow, staked $QUAK and staker rewards, and the
integrity of the published QVIX value.

## Trust assumptions

| Actor | Powers | Limits |
|---|---|---|
| Timelock (48 h, self-administered) | `DEFAULT_ADMIN_ROLE` everywhere: params, oracle/clock swap, calendar, compliance, unpause, market registry, `setProjectToken` (once), emergency settlement | every action is public for 48 h before it executes; the proposer can't skip the delay |
| Timelock proposer/executor (deployer or `TIMELOCK_PROPOSER`, ideally a multisig) | schedules/executes Timelock operations | — |
| Guardian (`GUARDIAN_ADDRESS`) | `pause()` on every pausable contract | cannot unpause, cannot move funds or change params |
| Keeper | calls `VolIndex.sample()` | no special role: sampling is permissionless and slot-deduplicated |
| Chainlink feeds, Robinhood stock tokens, USDG | prices / collateral | external; see risks 1, 7 |
| vAMM | owned by its FuturesMarket, immutable, no token custody, no callbacks | — |

The deployer EOA holds no role after deployment (verified by `test_deploymentWiring`).

## Top risks

### 1. Index manipulation via sampled prices
*Threat:* push a stock price at the sampling moment to inflate or deflate QVIX ahead of settlement or variance-swap
maturity.
*Mitigations:*
- Prices come only from Chainlink aggregated feeds (no DEX spot prices). Adapter checks: positive answer, complete
  round, no future timestamp, staleness ≤ 25 h, optional sequencer-uptime + 1 h grace.
- Equal-weight basket of 7 large caps: moving the basket return requires moving several feeds.
- Per-sample log return winsorized at ±25%, so one bad print can add at most 0.0625 to Σr² (and is visible in the
  `ReturnRecorded(clamped=true)` event).
- 147-return window: one sample is ~0.7% of the window.
- Futures settle on the average of 7 prints (a full trading day), not one print.
- Oracle is swappable via Timelock only (48 h public notice).
*Residual:* a compromised Chainlink feed. Guardian can pause sampling (`VolIndex.pause`) and the Timelock can switch
the oracle; markets have `emergencySettle` after 7 days.

### 2. Missed or delayed samples
*Threat:* keeper downtime, RPC outages or quorum failures leave gaps, and adversaries choose *when* to sample.
*Mitigations:*
- `sample()` is permissionless, so anyone can keep the index alive. One sample per hourly slot; calling early or
  late in a slot changes the timing by under an hour, and the next return covers the remainder.
- Each return records the number of periods it spans (`MarketClock.periodsBetween`). Variance is
  `Σr²/Σperiods`, so a missed hour doesn't bias the estimate.
- Gaps > 10 days re-base instead of creating a giant return.
- Missing assets carry their last price forward; the move is booked when the feed returns.
- Quorum 6/7: a sample with too many stale feeds reverts and can be retried.
- Funding stops accruing if the latest QVIX print is older than 4 days (`MAX_INDEX_AGE`). Settlement requires the last
  print at/before expiry to be within 4 days of expiry, otherwise only `emergencySettle` (Timelock, ≥ 7 days after
  expiry) can settle.

### 3. Settlement-time attacks
*Threats:* (a) choosing a favourable settlement round, (b) trading right before expiry with knowledge of the settlement
value, (c) LPs exiting right before a losing settlement, (d) double settlement.
*Mitigations:*
- (a) `settle(hint)` verifies `hint` is exactly the last round with `timestamp ≤ expiry`
  (`VolIndex.isLastRoundBefore`). The settlement value is deterministic, whoever calls it.
- (b) Trading stops at expiry; the settlement average covers the final trading day. QVIX itself is a 30-day realized
  measure, so the last day only moves it a little.
- (c) The vault marks open trader profit as a liability in `totalAssets()`. Withdrawals are capped by
  `requiredReserve()` (50% of each market's net open notional). New deposits are locked for 24 h and locked shares
  can't be transferred.
- (d) `settlePosition` sets `settled = true` before any value moves. Tested by unit tests and by the invariant
  `invariant_eachPositionSettlesOnce`.

### 4. Liquidation cascades in volatility spikes
*Threat:* a vol spike moves the futures mark sharply; liquidations sold into the vAMM push the mark further and trigger
more liquidations.
*Mitigations:*
- Margin checks use a **15-minute EMA** of the vAMM mark, not spot. One block cannot push accounts underwater, and
  a burst of liquidations moves the margin price gradually.
- **Partial liquidation:** positions above $10k notional lose 50% per liquidation call while equity is still at least
  half the maintenance requirement.
- Max leverage 5× (20% initial margin) with a 10% maintenance margin buffer. A position is rejected at open if it would
  already be liquidatable.
- Per-trade price impact limit (10%) for normal trades. Liquidations bypass it so they always execute, but they still
  respect the vAMM price bounds [1, 500].
- OI caps: net open notional ≤ 20% and per-side notional ≤ 50% of vault assets per market.
- Bad debt is booked explicitly (`BadDebt` event) and reimbursed to the vault by the insurance fund. Trader profit is
  capped at what the vault + insurance can pay in that transaction (`profitCapacity`), so a payout can never revert.
- Funding premium clamped to ±10% of the index per day.

### 5. Reentrancy / call ordering
All state-changing externals are `nonReentrant`. FuturesMarket uses a single "effects then interactions" pattern:
all position/aggregate state is updated first, and token movements are accumulated in a `Flows` struct and executed at
the end (`_execute`). The vAMM trade is quoted first (`view`) and executed last, asserting the quote matches.
Tokens move only through `SafeERC20`, and deposits measure received balances (fee-on-transfer safe). Slither reports no
High/Medium findings.

### 6. Vault share-price attacks
Inflation/donation attacks are blunted by OpenZeppelin ERC-4626 virtual shares with `_decimalsOffset = 6`.
Third-party deposits (`receiver != msg.sender`) are rejected, so nobody can reset someone else's deposit lock.
Trader losses that are not yet realized are *not* counted as vault assets (conservative).

### 7. External token risk
USDG (Paxos) and the stock tokens can be frozen or paused by their issuers, and Robinhood Chain's sequencer filters
sanctioned addresses. Variance swaps use pull payments, so one frozen party can't block the other side. Trader
payouts go to the internal MarginAccount balance first. Stock tokens are not held by the protocol: only their
Chainlink prices are used.

### 8. Governance risk
A malicious or compromised Timelock proposer can change parameters, swap the oracle, enable compliance, or
emergency-settle a stuck market, but only after a public 48 h delay. During that delay users can exit (close
positions, withdraw margin and free LP liquidity) unless the guardian pauses. Recommended: proposer = multisig,
guardian = a separate multisig/ops key, and monitor `CallScheduled` events.

### 9. Pausing
Pause blocks all user actions on the paused contract, including exits, so a suspected exploit can be frozen
completely. Unpausing requires the Timelock (48 h). This is a deliberate trade: availability is given up to protect
funds during an incident.

### 10. Project token ($QUAK)
Disabled until `setProjectToken` is called once through the Timelock. Fee-discount gaming (stake → trade → unstake)
is limited by a 7-day unstake cooldown, during which the stake neither earns nor counts for discounts. If the hooks
contract misbehaves, `FeeCollector.feeDiscountBps` catches the revert and clamps the discount, so trading is never
blocked.

## Slither triage (remaining Low / Informational)

Run: `cd contracts && python -m slither . --config-file slither.config.json`

| Detector | Count | Disposition |
|---|---|---|
| `timestamp` | 34 | Intended: the protocol is time-based (market hours, expiries, staleness, locks). Sequencer timestamp drift is minutes at most, far below every threshold used. |
| `calls-loop` | 23 | Bounded loops over trusted contracts (≤ 16 basket assets, ≤ 16 markets, ≤ 25 batch liquidations, try/catch). |
| `reentrancy-benign` | 3 | Calls to trusted protocol contracts, guarded by `nonReentrant`. |
| `missing-inheritance`, `unindexed-event-address`, `unused-state`, `costly-loop`, `cyclomatic-complexity` | 8 | Style / informational. |

Fixed during development: every Medium (reentrancy-no-eth in FuturesMarket → `Flows` CEI refactor;
divide-before-multiply → `mulDiv` / no intermediate division; unused returns now checked; strict equalities replaced;
locals explicitly initialized). The calendar library's intentional floor divisions are annotated.

## Test evidence

* Unit + fuzz: `forge test` (110+ tests); the QVIX ⇄ TypeScript reference FFI fuzz; vAMM round-trip never profits.
* Invariants (`test/invariant`): MarginAccount balance == Σfree + Σlocked; locked margin == Σ open-position margin;
  long/short aggregates == Σ positions; vault + insurance ≥ open trader profit; vault `totalAssets ≤ balance`;
  each position settles at most once.
* Fork tests against Robinhood Chain mainnet with the real USDG, stock tokens and Chainlink feeds.
