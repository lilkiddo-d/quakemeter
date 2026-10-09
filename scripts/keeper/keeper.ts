/**
 * Quakemeter sampler keeper.
 *
 * Every INTERVAL_SECONDS it asks VolIndex.canSample() (market open and this hourly slot not sampled yet) and,
 * if so, sends VolIndex.sample() by running `forge script script/Ops.s.sol:Sample` signed with the Foundry
 * keystore account (default: quakemeter-keeper). This process never sees the private key: forge decrypts the
 * keystore itself using KEEPER_PASSWORD_FILE.
 *
 *   pnpm keeper            # loop forever
 *   pnpm keeper:once       # single tick (cron / Task Scheduler friendly)
 *
 * Env:
 *   CHAIN_ID               4663 (default) or 31337 for a local fork
 *   RPC_URL                defaults to the chain's public RPC from config/chains.json (or http://127.0.0.1:8545)
 *   KEEPER_ACCOUNT         Foundry keystore account name (default quakemeter-keeper)
 *   KEEPER_PASSWORD_FILE   path to a file containing the keystore password (required for unattended runs)
 *   KEEPER_UNLOCKED_SENDER local fork only: send via anvil's unlocked account instead of a keystore
 *   INTERVAL_SECONDS       default 300 (sampling slots are hourly; 5-minute polling catches each slot early)
 *   DRY_RUN=1              only report what would be done
 */
import { spawn } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, http, parseAbi, type Address } from "viem";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const chainId = Number(process.env.CHAIN_ID ?? 4663);
const chains = JSON.parse(readFileSync(join(root, "config", "chains.json"), "utf8"));
const cfgChain = chainId === 31337 ? "4663" : String(chainId);
const rpcUrl =
  process.env.RPC_URL ?? (chainId === 31337 ? "http://127.0.0.1:8545" : chains[cfgChain]?.rpcUrls?.[0]);
const account = process.env.KEEPER_ACCOUNT ?? "quakemeter-keeper";
const passwordFile = process.env.KEEPER_PASSWORD_FILE;
const unlockedSender = process.env.KEEPER_UNLOCKED_SENDER;
const intervalMs = Number(process.env.INTERVAL_SECONDS ?? 300) * 1000;
const dryRun = process.env.DRY_RUN === "1";
const once = process.argv.includes("--once");

const deploymentsPath = join(root, "deployments", `${chainId}.json`);
if (!existsSync(deploymentsPath)) {
  console.error(`No deployment found at ${deploymentsPath}. Deploy first (see DEPLOY.md).`);
  process.exit(1);
}
const deployment = JSON.parse(readFileSync(deploymentsPath, "utf8"));
const volIndex = deployment.VolIndex as Address;

const abi = parseAbi([
  "function canSample() view returns (bool)",
  "function latestIndex() view returns (uint256 qvix, uint256 timestamp)",
  "function latestRoundId() view returns (uint256)",
  "function isReady() view returns (bool)",
]);
const client = createPublicClient({ transport: http(rpcUrl, { retryCount: 3, timeout: 30_000 }) });

function log(...args: unknown[]) {
  console.log(new Date().toISOString(), ...args);
}

function runForge(): Promise<number> {
  const args = ["script", "script/Ops.s.sol:Sample", "--rpc-url", rpcUrl!, "--broadcast", "--slow"];
  if (unlockedSender) {
    if (chainId !== 31337) throw new Error("KEEPER_UNLOCKED_SENDER is only allowed on a local fork");
    args.push("--unlocked", "--sender", unlockedSender);
  } else {
    args.push("--account", account);
    if (passwordFile) args.push("--password-file", passwordFile);
  }
  return new Promise((resolve) => {
    const child = spawn("forge", args, {
      cwd: join(root, "contracts"),
      stdio: ["inherit", "pipe", "pipe"],
      env: { ...process.env, FOUNDRY_DISABLE_NIGHTLY_WARNING: "1" },
    });
    child.stdout.on("data", (d) => {
      const line = String(d);
      if (/sampled round|nothing to do|Error|error/i.test(line)) process.stdout.write(line);
    });
    child.stderr.on("data", (d) => process.stderr.write(d));
    child.on("close", (code) => resolve(code ?? 1));
  });
}

async function tick() {
  try {
    const can = await client.readContract({ address: volIndex, abi, functionName: "canSample" });
    if (!can) {
      const [qvix, ts] = await client.readContract({ address: volIndex, abi, functionName: "latestIndex" });
      log(`idle — market closed or slot already sampled. QVIX=${Number(qvix) / 1e18} @ ${new Date(Number(ts) * 1000).toISOString()}`);
      return;
    }
    if (dryRun) {
      log("DRY_RUN: would call VolIndex.sample()");
      return;
    }
    log("sampling...");
    const code = await runForge();
    const [qvix] = await client.readContract({ address: volIndex, abi, functionName: "latestIndex" });
    const ready = await client.readContract({ address: volIndex, abi, functionName: "isReady" });
    log(`forge exited ${code}; QVIX=${(Number(qvix) / 1e18).toFixed(2)} ready=${ready}`);
  } catch (e) {
    log("tick failed:", (e as Error).message);
  }
}

log(`keeper on chain ${chainId} via ${rpcUrl}, VolIndex ${volIndex}, account ${unlockedSender ? "unlocked:" + unlockedSender : account}`);
if (!passwordFile && !unlockedSender && !once) {
  log("warning: KEEPER_PASSWORD_FILE not set — forge will prompt for the keystore password on each sample");
}
await tick();
if (!once) setInterval(tick, intervalMs);
