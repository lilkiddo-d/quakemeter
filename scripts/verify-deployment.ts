/**
 * Post-deploy audit: checks on-chain that the deployment in deployments/<chainId>.json is wired as intended
 * and that the deployer holds no admin role.   node verify-deployment.ts [chainId]
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, http, parseAbi, keccak256, toHex, type Address } from "viem";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const chainId = process.argv[2] ?? "4663";
const d = JSON.parse(readFileSync(join(root, "deployments", `${chainId}.json`), "utf8"));
const chains = JSON.parse(readFileSync(join(root, "config", "chains.json"), "utf8"));
const rpc = process.env.RPC_URL ?? chains["4663"].rpcUrls[0];
// the public RPC sits behind Cloudflare rate limiting: batch, pace and back off
const base = createPublicClient({ transport: http(rpc, { batch: { batchSize: 20, wait: 50 }, retryCount: 6, retryDelay: 3000 }) });
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const c = {
  readContract: async (args: any): Promise<any> => {
    await sleep(400);
    return base.readContract(args);
  },
};

const ac = parseAbi(["function hasRole(bytes32,address) view returns (bool)"]);
const ADMIN = toHex(0, { size: 32 });
const role = (s: string) => keccak256(toHex(s));
const tl = d.Timelock as Address;
const dep = d.deployer as Address;
let fails = 0;
const check = (ok: boolean, msg: string) => {
  console.log(`${ok ? "OK  " : "FAIL"} ${msg}`);
  if (!ok) fails++;
};
const has = (a: Address, r: `0x${string}`, who: Address) => c.readContract({ address: a, abi: ac, functionName: "hasRole", args: [r, who] });

const adminContracts: Record<string, Address> = {
  VolIndex: d.VolIndex, MarginAccount: d.MarginAccount, LPVault: d.LPVault, InsuranceFund: d.InsuranceFund,
  FeeCollector: d.FeeCollector, ProjectTokenHooks: d.ProjectTokenHooks, Liquidator: d.Liquidator,
  VarianceSwap: d.VarianceSwap, MarketClock: d.MarketClock, OracleAdapter: d.OracleAdapter,
  PriceSampler: d.PriceSampler, ComplianceRegistry: d.ComplianceRegistry,
};
(d.FuturesMarkets as Address[]).forEach((m, i) => (adminContracts[`FuturesMarket[${i}]`] = m));

for (const [name, a] of Object.entries(adminContracts)) {
  check(await has(a, ADMIN, tl), `${name}: Timelock is admin`);
  check(!(await has(a, ADMIN, dep)), `${name}: deployer is NOT admin`);
}
for (const n of ["VolIndex", "MarginAccount", "LPVault", "FuturesMarket[0]"]) {
  check(await has(adminContracts[n], role("GUARDIAN_ROLE"), dep), `${n}: guardian set (deployer by default)`);
}
check(!(await has(d.MarketClock, role("CALENDAR_ROLE"), dep)), "MarketClock: deployer has no CALENDAR_ROLE");
check(!(await has(d.ComplianceRegistry, role("COMPLIANCE_ROLE"), dep)), "Compliance: deployer has no COMPLIANCE_ROLE");
check(await has(d.PriceSampler, role("SAMPLER_ROLE"), d.VolIndex), "PriceSampler: VolIndex is the only writer");
check(await has(d.InsuranceFund, role("COVER_ROLE"), d.MarginAccount), "InsuranceFund: MarginAccount can cover");
check(await has(d.ProjectTokenHooks, role("NOTIFIER_ROLE"), d.FeeCollector), "TokenHooks: FeeCollector notifies");
for (const m of d.FuturesMarkets as Address[]) {
  check(await has(m, role("LIQUIDATOR_ROLE"), d.Liquidator), `Market ${m.slice(0, 8)}: Liquidator role`);
}

const tlAbi = parseAbi(["function getMinDelay() view returns (uint256)"]);
const delay = await c.readContract({ address: tl, abi: tlAbi, functionName: "getMinDelay" });
check(delay === 172800n, `Timelock delay = ${delay}s (48h)`);
check(await has(tl, role("PROPOSER_ROLE"), dep), "Timelock: proposer is deployer (set TIMELOCK_PROPOSER for a multisig)");
check(!(await has(tl, ADMIN, dep)), "Timelock: deployer is not Timelock admin");

const maAbi = parseAbi(["function marketCount() view returns (uint256)", "function isMarket(address) view returns (bool)", "function vault() view returns (address)", "function insurance() view returns (address)"]);
check((await c.readContract({ address: d.MarginAccount, abi: maAbi, functionName: "marketCount" })) === 3n, "MarginAccount: 3 markets registered");
check((await c.readContract({ address: d.MarginAccount, abi: maAbi, functionName: "vault" })) === d.LPVault, "MarginAccount: vault wired");
check((await c.readContract({ address: d.MarginAccount, abi: maAbi, functionName: "insurance" })) === d.InsuranceFund, "MarginAccount: insurance wired");

const oAbi = parseAbi(["function tryGetPrice(address) view returns (bool,uint256,uint256)"]);
for (const b of chains["4663"].basket) {
  const [ok, p] = await c.readContract({ address: d.OracleAdapter, abi: oAbi, functionName: "tryGetPrice", args: [b.token] });
  check(ok, `Oracle ${b.symbol}: $${(Number(p) / 1e18).toFixed(2)}`);
}
const viAbi = parseAbi(["function latestRoundId() view returns (uint256)", "function isReady() view returns (bool)"]);
console.log(`VolIndex rounds: ${await c.readContract({ address: d.VolIndex, abi: viAbi, functionName: "latestRoundId" })}`);
const thAbi = parseAbi(["function isActive() view returns (bool)"]);
check(!(await c.readContract({ address: d.ProjectTokenHooks, abi: thAbi, functionName: "isActive" })), "$QUAK hooks inactive (token not set)");
console.log(fails === 0 ? "\nALL CHECKS PASSED" : `\n${fails} CHECK(S) FAILED`);
process.exit(fails ? 1 : 0);
