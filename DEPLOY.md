# Deploying Quakemeter to Robinhood Chain

Everything signs through Foundry keystores. Nothing in this repo creates, stores or prints a private key.

**Prerequisites:** Foundry ≥ 1.8 (`forge`, `cast`, `anvil`), Node ≥ 22, pnpm, and some ETH on Robinhood Chain for
the deployer (the full deploy simulates at ~45.2M gas ≈ 0.002 ETH at current fees; keep ~0.01 ETH) and for the
keeper (one sample ≈ 0.3–0.4M gas, 7 per trading day).

> Windows note: on this machine Windows Smart App Control / Application Control blocked `cast.exe` while
> `forge.exe` ran fine. If `cast` is blocked for you too, allow it (Windows Security → App & browser control) or run
> the `cast` steps from WSL/macOS/Linux. The deploy and keeper only need `forge`.

---

## 1. Import the deployer key into an encrypted Foundry keystore

```bash
cast wallet import quakemeter-deployer --interactive
```

(Also create the keeper account now; it needs no protocol role, only gas money.)

```bash
cast wallet import quakemeter-keeper --interactive
```

## 2. Deploy, wire, hand admin to the Timelock and verify — one command

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.mainnet.chain.robinhood.com --account quakemeter-deployer --sender <DEPLOYER_ADDRESS> --broadcast --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ --slow
```

This deploys all contracts (Timelock, MarketClock with the 2026–2027 NYSE calendar, OracleAdapter with the 7 basket
feeds, PriceSampler, VolIndex, MarginAccount, LPVault, InsuranceFund, FeeCollector, ProjectTokenHooks,
ComplianceRegistry (off), Liquidator, VarianceSwap and the next three monthly FuturesMarkets with their vAMMs). It
wires them together, gives the guardian `GUARDIAN_ROLE`, hands `DEFAULT_ADMIN_ROLE` to the 48 h Timelock, renounces
every deployer role and verifies the sources on Blockscout. It writes:

* `deployments/4663.json` — all addresses + expiries
* `app/src/config/generated/deployments.4663.json` — the frontend config

Optional environment variables (set them **before** running; strongly recommended for production):

| Variable | Default | Meaning |
|---|---|---|
| `TIMELOCK_PROPOSER` | deployer | proposer + executor of the Timelock (use a multisig) |
| `GUARDIAN_ADDRESS` | deployer | can pause any contract instantly (cannot unpause) |
| `TREASURY_ADDRESS` | Timelock | receives the treasury share of fees |
| `FIRST_EXPIRY_MIN_LEAD_DAYS` | 45 | first expiry at least this many days out (index warm-up is ~30 days) |

If verification fails for any contract (Blockscout rate limits), rerun only verification:

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.mainnet.chain.robinhood.com --account quakemeter-deployer --sender <DEPLOYER_ADDRESS> --resume --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

## 3. Later: wire the $QUAK token (only after it launches)

`setProjectToken` can be called once, only by the Timelock. Schedule it, wait 48 hours, then execute (details in
[TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md)):

```bash
cd contracts && forge script script/Ops.s.sol:SetProjectToken --sig "schedule(address)" <QUAK_TOKEN_ADDRESS> --rpc-url https://rpc.mainnet.chain.robinhood.com --account quakemeter-deployer --sender <DEPLOYER_ADDRESS> --broadcast
```

```bash
cd contracts && forge script script/Ops.s.sol:SetProjectToken --sig "execute(address)" <QUAK_TOKEN_ADDRESS> --rpc-url https://rpc.mainnet.chain.robinhood.com --account quakemeter-deployer --sender <DEPLOYER_ADDRESS> --broadcast
```

Then set `NEXT_PUBLIC_PROJECT_TOKEN=<QUAK_TOKEN_ADDRESS>` on Vercel and redeploy the app.

---

## Start the hourly sampler (keeper)

Sampling is permissionless (`VolIndex.sample()`), at most once per hourly slot during US market hours. The keeper
polls `canSample()` every 5 minutes and sends `sample()` through `forge script` signed with the
`quakemeter-keeper` keystore.

1. Send a little ETH to the keeper address (`cast wallet address --account quakemeter-keeper`).
2. Put the keeper keystore password in a file only you can read (e.g. `~/.quakemeter-keeper-pass`).
3. Install the workspace and run the keeper:

```bash
pnpm install
```

```bash
CHAIN_ID=4663 KEEPER_PASSWORD_FILE=$HOME/.quakemeter-keeper-pass pnpm keeper
```

Run it under a process manager (pm2, systemd, or a Windows scheduled task at log-on). For cron or Task Scheduler,
run `pnpm keeper:once` every 5 minutes instead. Start it right after the deploy: the index needs **147 hourly
returns (≈ 21 trading days ≈ 30 calendar days)** before it is "ready". Anyone else can also call `sample()`, so a
second keeper on another machine adds redundancy at no risk.

## When futures trading opens

Trading can open only when `VolIndex.isReady()` is true, i.e. **after ~30 calendar days of samples** (21 trading
days × 7 samples). Then:

1. **Seed the LP vault first.** Open-interest caps are a percentage of vault assets (net ≤ 20%, per side ≤ 50% per
   market), so an empty vault means zero capacity. Deposit USDG through the app's Vault page. Optionally top up the
   insurance fund by transferring USDG to the `InsuranceFund` address.
2. **Open each market.** `FuturesMarket.openTrading()` is permissionless and starts the vAMM at the current QVIX. Use
   the "Open trading" button on the market's Trade page, or:

```bash
cast send <FUTURES_MARKET_ADDRESS> "openTrading()" --rpc-url https://rpc.mainnet.chain.robinhood.com --account quakemeter-keeper
```

Markets that are within 1 day of expiry can't be opened. After expiry anyone settles with `settle(hintRound)` (the
app computes the hint) and then each position with `settlePosition(id)`.

**Adding the next monthly expiry** (deploy now, registration via the Timelock after 48 h):

```bash
cd contracts && forge script script/Ops.s.sol:NewExpiry --sig "deploy(uint256,uint256)" 2027 2 --rpc-url https://rpc.mainnet.chain.robinhood.com --account quakemeter-deployer --sender <DEPLOYER_ADDRESS> --broadcast --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

```bash
cd contracts && forge script script/Ops.s.sol:NewExpiry --sig "register(address)" <NEW_MARKET_ADDRESS> --rpc-url https://rpc.mainnet.chain.robinhood.com --account quakemeter-deployer --sender <DEPLOYER_ADDRESS> --broadcast
```

(Add the new address to `FuturesMarkets` in `deployments/4663.json` and in
`app/src/config/generated/deployments.4663.json` so the app lists it.)

---

## Deploy the frontend (/app) to Vercel

1. Import the Git repository in Vercel → **Root Directory: `app`**. Keep "Include files outside the root
   directory" enabled; the app reads `../config/chains.json`.
2. Framework preset **Next.js**. Install command `pnpm install`, build command `pnpm build` (defaults detected from
   `app/package.json`).
3. Environment variables:

| Variable | Value |
|---|---|
| `NEXT_PUBLIC_CHAIN_ID` | `4663` |
| `NEXT_PUBLIC_RPC_URL` | optional: a dedicated Robinhood Chain RPC (Alchemy/Goldsky/…); defaults to the public RPC |
| `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` | optional: enables WalletConnect wallets (injected wallets work without it) |
| `NEXT_PUBLIC_PROJECT_TOKEN` | empty until $QUAK is wired (empty = all token features hidden) |
| `NEXT_PUBLIC_GEOBLOCK_COUNTRIES` | optional, e.g. `US,CU,IR,KP,SY,RU` (uses Vercel's `x-vercel-ip-country`) |

4. Commit `app/src/config/generated/deployments.4663.json` (written by the deploy script) before deploying, so the
   app knows the contract addresses.

---

## Rehearsal: local fork + mainnet dry run (what was run before handoff)

```bash
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 31337 --port 8555
```

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8555 --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

(`0xf39F…2266` is anvil's built-in unlocked dev account; the fork uses chain id 31337 so its files,
`deployments/31337.json`, can never be confused with mainnet.) Point the app at it with
`NEXT_PUBLIC_CHAIN_ID=31337 NEXT_PUBLIC_RPC_URL=http://127.0.0.1:8555 pnpm app:dev`.

Mainnet dry run (simulation only, nothing is sent, no key needed; writes `deployments/4663.dry-run.json`):

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.mainnet.chain.robinhood.com --sender <YOUR_DEPLOYER_ADDRESS>
```
