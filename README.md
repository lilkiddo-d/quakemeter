# Quakemeter

**QVIX: an on-chain volatility index for tokenized stocks on Robinhood Chain, plus cash-settled QVIX futures
and variance swaps, so traders can bet on calm or chaos.**

> Quakemeter is independent and not affiliated with or endorsed by Robinhood. Volatility products are risky;
> read the in-app risk disclosure (`/risk`).

## What it is

* **QVIX** is the annualized realized volatility of an equal-weight basket of 7 tokenized stocks (AAPL, AMZN, GOOGL,
  META, MSFT, NVDA, TSLA), computed on-chain from Chainlink prices sampled every hour during US market hours. It
  uses a 147-return (~30-day) ring buffer. See [docs/METHODOLOGY.md](docs/METHODOLOGY.md).
* **QVIX futures:** monthly expiries (third Friday, 16:00 ET), long/short with isolated USDG margin up to 5×, priced by
  a virtual AMM with funding toward spot QVIX. They settle on the average of the last 7 QVIX prints at or before
  expiry.
* **LP vault (ERC-4626):** counterparty to all futures, with OI caps, reserves, an insurance fund for bad debt and
  permissionless liquidations.
* **Variance swaps (optional):** peer-to-peer, fully collateralized, fixed strike vs realized variance.
* **$QUAK hooks:** staking for fee sharing and fee-discount tiers. They stay **off** until the externally launched
  token is wired once through the Timelock ([TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md)).

```
 Chainlink stock feeds ──► OracleAdapter ──► VolIndex ◄── keeper / anyone: sample() hourly
                                               │  (MarketClock: NYSE hours, DST, holidays)
                                               ▼
                                         PriceSampler (ring buffers, running Σr², Σperiods)
                                               │ QVIX rounds + cumulative accumulators
             ┌─────────────────────────────────┼──────────────────────────────┐
             ▼                                 ▼                              ▼
   FuturesMarket (per expiry) ── vAMM     settlement (avg of 7 prints)   VarianceSwap (P2P)
     │  isolated margin, funding, liquidations via Liquidator
     ▼
 MarginAccount (USDG custody) ◄─► LPVault (ERC-4626 counterparty) ◄── FeeCollector ──► Insurance / stakers / treasury
                                        ▲                                   ▲
                                  InsuranceFund (bad debt)        ProjectTokenHooks ($QUAK, off until set)
 ComplianceRegistry (allowlist hook, off) · Timelock 48h (admin of everything) · Guardian (pause only)
```

## Repository

| Path | Contents |
|---|---|
| `contracts/` | Foundry project. `src/` (15 contracts), `test/` (unit, fuzz, FFI reference, invariant, fork), `script/Deploy.s.sol` (one-shot deploy), `script/Ops.s.sol` (keeper tick, `setProjectToken`, new expiries) |
| `app/` | Next.js + wagmi/viem + RainbowKit frontend: QVIX chart, trading per expiry, positions & liquidation price, LP vault, variance-swap board, explainer, risk disclosure, optional geoblock |
| `scripts/` | Hourly sampler keeper (`keeper/keeper.ts`) and the TypeScript reference implementation of QVIX (`reference/qvix.ts`) |
| `config/` | `chains.json` / `chains.ts`: chain ID, RPC, explorer, USDG, stock tokens and Chainlink feeds with source links |
| `deployments/` | `<chainId>.json` written by the deploy script |
| `docs/` | Methodology |

Key documents: [DEPLOY.md](DEPLOY.md) · [THREAT_MODEL.md](THREAT_MODEL.md) · [DECISIONS.md](DECISIONS.md) ·
[TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md) · [docs/METHODOLOGY.md](docs/METHODOLOGY.md)

## Quick start

```bash
pnpm install
```

```bash
cd contracts && forge build && forge test --no-match-path "test/fork/*"
```

Fork tests against Robinhood Chain mainnet (real USDG, stock tokens and feeds; `ROBINHOOD_RPC_URL` overrides the RPC):

```bash
cd contracts && forge test --match-path "test/fork/*" -vv
```

Coverage and static analysis:

```bash
pnpm coverage
```

```bash
cd contracts && python -m slither . --config-file slither.config.json
```

Reference implementation tests: `pnpm --filter quakemeter-scripts test`. Frontend: `pnpm app:dev` / `pnpm app:build`.

## Status at handoff

* All Foundry tests pass: unit, fuzz, invariant, the FFI comparison against the TypeScript reference, and the
  mainnet fork tests.
* Core contracts are at ≥ 95% line coverage.
* Slither: no High or Medium findings (Low/Informational triage in THREAT_MODEL.md).
* The full deploy ran against a local anvil fork of mainnet, and a mainnet dry run (no broadcast) succeeded. Live
  hourly samples were taken on the fork with the real Chainlink prices.
* Mainnet is **not** deployed yet. That's step 2 of [DEPLOY.md](DEPLOY.md).
