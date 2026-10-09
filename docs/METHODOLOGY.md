# QVIX methodology

QVIX is the **annualized realized volatility** of an equal-weight basket of tokenized US stocks on Robinhood Chain,
computed entirely on-chain from Chainlink prices sampled once per hour during US regular trading hours.

| Parameter | Value | Where |
|---|---|---|
| Basket | AAPL, AMZN, GOOGL, META, MSFT, NVDA, TSLA (stock tokens, equal weight) | `config/chains.json` |
| Price source | Chainlink price feeds on Robinhood Chain (8 decimals, 0.5% deviation / 24h heartbeat) | `OracleAdapter` |
| Sampling | one sample per hourly slot, 09:30–16:00 America/New_York, Mon–Fri, NYSE holidays & early closes excluded | `MarketClock` |
| Slots per full day | 7 (`[09:30,10:30) … [15:30,16:00)`) | `MarketClock` |
| Window | 147 returns (21 trading days × 7 ≈ 30 calendar days) | `PriceSampler.windowSize` |
| Annualization | 1764 periods per year (252 × 7) | `VolIndex.periodsPerYear` |
| Return clamp | ±0.25 natural-log return per sample (winsorized) | `PriceSampler.maxAbsLogReturn` |
| Quorum | 6 of 7 assets must have a valid price for a sample to be taken | `PriceSampler.minQuorum` |
| Staleness | a feed older than 25 h (heartbeat + 1 h) is treated as missing | `OracleAdapter` |
| History | last 8192 published values kept on-chain (~4.6 years) | `VolIndex.HISTORY_CAPACITY` |

## 1. Sampling

`VolIndex.sample()` is permissionless; the keeper in `/scripts/keeper` calls it every hour. It succeeds only when
`MarketClock.isOpen(now)` and the current hourly slot has not been sampled yet, so there is **at most one sample per
slot** no matter who calls it or how often.

The clock converts UTC to US Eastern time on-chain (second Sunday of March 02:00 → first Sunday of November 02:00
is EDT, otherwise EST). Holidays and 13:00 early closes are stored on-chain (2026–2027 are seeded at deploy; later
years are added through the Timelock with `setHolidays` / `setEarlyClose`).

For each basket asset the `OracleAdapter` returns a price only if the answer is positive, the round is complete, the
timestamp is not in the future and not older than the staleness bound, and (when configured) the L2 sequencer
uptime feed reports the sequencer up for more than one hour. Corporate actions are already reflected in the
Chainlink stock-token prices (per Robinhood's docs), so splits/dividends do not create artificial jumps.

## 2. Basket return

Let `P_i(t)` be the last valid price of asset `i` at sample `t`. With `A` the set of assets that are valid now and
also had a previous valid price:

```
R_t   = (1/|A|) · Σ_{i∈A} P_i(t) / P_i(t_prev,i)        (equal-weight gross return, rebalanced every sample)
r_t   = clamp( ln(R_t), −0.25, +0.25 )
```

An asset with a missing price keeps its last price; when it comes back its ratio spans the whole gap, so a stale
asset never removes variance (it just reports it late). If fewer than 6 assets are valid the whole sample reverts.

## 3. Periods

Each return records how many sampling periods it spans, `n_t ≥ 1`, from the clock:

* same day: slot difference (normally 1)
* across days: remaining slots of the first day + 1 overnight boundary + slots of the second day up to the sample
  + all slots of any full trading days in between (weekends/holidays count 0)

So a normal day contributes exactly 7 periods (6 intraday hours + the overnight/weekend gap), matching the 1764
periods-per-year annualization. A missed keeper hour produces one return with `n_t = 2` instead of two returns,
which leaves the variance estimate unbiased. If the gap exceeds 10 calendar days the sampler **re-bases** (records
prices, no return) rather than booking one huge return.

## 4. Index

The window keeps the last 147 returns in a ring buffer together with running sums (exact integer add/subtract of
the stored values, so there is no drift and no loop over the window):

```
S2 = Σ r_t²          N = Σ n_t          (over the window)
annualVariance = 1764 · S2 / N                          (zero-mean convention, as for variance swaps)
QVIX           = 100 · sqrt(annualVariance)             (vol points; 25.0 = 25% annualized volatility)
```

`VolIndex.isReady()` becomes true once the window holds 147 returns — about **21 trading days (~30 calendar days)**
after the first sample. Futures can only open after that.

Every sample publishes a `Round {timestamp, qvix, cumSumSq, cumPeriods}` and emits
`IndexUpdated(roundId, timestamp, qvix, annualVariance, ready, logReturn)`. Getters: `latestIndex()`,
`latestRoundId()`, `getRound(id)`, `currentIndex()`, `averageIndexAt(cutoff, hint, n)`,
`realizedVarianceBetween(a, b)`.

## 5. Settlement values

* **Futures** settle at the **average of the last 7 QVIX prints with timestamp ≤ expiry** (one trading day), capped
  at 400. Expiry is the third Friday of the month at 16:00 ET. The settler passes the round id of the last print at
  or before expiry; the contract verifies it.
* **Variance swaps** use `realizedVarianceBetween(start, end)` from the cumulative accumulators: the annualized
  realized variance of the returns that begin at or after the fill and end at or before maturity, in vol points²,
  capped at (2.5 × strike vol)².

## 6. Reference implementation

`scripts/reference/qvix.ts` re-implements the method off-chain (BigInt integer steps with Solidity rounding,
float64 `ln`/`sqrt`). `contracts/test/fuzz/VolIndexReference.t.sol` drives the on-chain `VolIndex` with random price
paths (including invalid prices, multi-period gaps, re-bases and clamping) and checks it matches the TypeScript
output within 1e-9 relative error via Foundry FFI.

## 7. Known limitations

* **Feed granularity.** Chainlink stock feeds on Robinhood Chain update on a 0.5% deviation threshold or a 24 h
  heartbeat. Hourly moves are often smaller than 0.5% per stock, so individual samples can see an unchanged price
  and the next sample sees the accumulated move. Over a 147-return window this mostly redistributes variance
  between samples. It still adds measurement noise and some downward bias for very calm markets. The oracle is
  swappable (`VolIndex.setOracle`, Timelock). A low-latency source (e.g. Chainlink Data Streams, if it becomes
  available on the chain) can replace it without touching any other contract.
* **Regular hours only.** Moves during extended / 24-5 trading are captured at the next regular-session sample as
  part of the overnight return; they are not sampled separately.
* **Early closes** are treated as shorter days (fewer slots); annualization still assumes 7 periods per day, a
  negligible bias.
* **Basket changes** (adding/removing stocks) require a new `PriceSampler` deployment and a fresh 30-day warm-up.
