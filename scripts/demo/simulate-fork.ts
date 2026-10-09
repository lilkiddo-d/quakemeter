/**
 * LOCAL FORK ONLY. Drives a forked deployment (chain 31337) through ~30 trading days of hourly samples with a
 * random-walk on the DemoOracle (contracts/script/LocalDemo.s.sol), then seeds the LP vault and opens trading on
 * the first market, so the whole frontend can be exercised. Uses anvil's unlocked dev account; no keys.
 *
 *   RPC_URL=http://127.0.0.1:8555 DEMO_ORACLE=0x... node demo/simulate-fork.ts
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createPublicClient, createWalletClient, http, parseAbi, type Address, defineChain, keccak256, encodeAbiParameters, toHex,
} from "viem";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const rpc = process.env.RPC_URL ?? "http://127.0.0.1:8555";
const demoOracle = process.env.DEMO_ORACLE as Address;
const dev: Address = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const dep = JSON.parse(readFileSync(join(root, "deployments", "31337.json"), "utf8"));
const chain = defineChain({
  id: 31337,
  name: "fork",
  nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [rpc] } },
});
const pub = createPublicClient({ chain, transport: http(rpc) });
if ((await pub.getChainId()) !== 31337) throw new Error("refusing: not a local fork");
const wallet = createWalletClient({ chain, transport: http(rpc), account: dev });

const viAbi = parseAbi([
  "function canSample() view returns (bool)",
  "function sample() returns (uint256)",
  "function isReady() view returns (bool)",
  "function latestIndex() view returns (uint256,uint256)",
  "function sampler() view returns (address)",
]);
const sAbi = parseAbi(["function assets() view returns (address[])", "function returnCount() view returns (uint256)"]);
const oAbi = parseAbi(["function set(address[] assets, uint256[] prices)", "function price(address) view returns (uint256)"]);
const erc20 = parseAbi([
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
]);
const vaultAbi = parseAbi(["function deposit(uint256,address) returns (uint256)"]);
const mktAbi = parseAbi(["function openTrading()", "function status() view returns (uint8)"]);

const send = async (address: Address, abi: any, functionName: string, args: unknown[] = []) => {
  const hash = await wallet.writeContract({ address, abi, functionName, args } as never);
  return pub.waitForTransactionReceipt({ hash });
};
const rpcCall = (method: string, params: unknown[]) => pub.request({ method: method as never, params: params as never });

const sampler = (await pub.readContract({ address: dep.VolIndex, abi: viAbi, functionName: "sampler" })) as Address;
const assets = (await pub.readContract({ address: sampler, abi: sAbi, functionName: "assets" })) as Address[];
let prices = await Promise.all(
  assets.map((a) => pub.readContract({ address: demoOracle, abi: oAbi, functionName: "price", args: [a] }) as Promise<bigint>),
);

let seed = 7;
const rand = () => ((seed = (seed * 1103515245 + 12345) % 2 ** 31) / 2 ** 31) * 2 - 1;
let n = 0;
while (!(await pub.readContract({ address: dep.VolIndex, abi: viAbi, functionName: "isReady" }))) {
  // advance to the next hour that the clock accepts
  for (let i = 0; i < 200; i++) {
    await rpcCall("evm_increaseTime", [3600]);
    await rpcCall("evm_mine", []);
    if (await pub.readContract({ address: dep.VolIndex, abi: viAbi, functionName: "canSample" })) break;
  }
  const common = rand() * 0.006; // market factor
  prices = prices.map((p) => {
    const move = common + rand() * 0.008;
    return (p * BigInt(Math.round((1 + move) * 1e6))) / 1_000_000n;
  });
  await send(demoOracle, oAbi, "set", [assets, prices]);
  await send(dep.VolIndex, viAbi, "sample");
  n++;
  if (n % 20 === 0) {
    const c = await pub.readContract({ address: sampler, abi: sAbi, functionName: "returnCount" });
    console.log(`samples ${n}, window ${c}/147`);
  }
}
const [q] = (await pub.readContract({ address: dep.VolIndex, abi: viAbi, functionName: "latestIndex" })) as [bigint, bigint];
console.log(`QVIX ready: ${(Number(q) / 1e18).toFixed(2)} after ${n} samples`);

// Give the dev account 1,000,000 USDG on the fork. USDG keeps balances in mapping slot 1 (found with forge-std
// stdstore on a fork: keccak256(abi.encode(holder, 1))).
const usdg = dep.Collateral as Address;
const balSlot = keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [dev, 1n]));
await rpcCall("anvil_setStorageAt", [usdg, balSlot, toHex(2_000_000n * 10n ** 6n, { size: 32 })]);
const bal = (await pub.readContract({ address: usdg, abi: erc20, functionName: "balanceOf", args: [dev] })) as bigint;
const seedAmt = bal / 2n; // half to the vault, half stays in the wallet for trading in the UI
await send(usdg, erc20, "approve", [dep.LPVault, seedAmt]);
await send(dep.LPVault, vaultAbi, "deposit", [seedAmt, dev]);
console.log(`seeded vault with ${Number(seedAmt) / 1e6} USDG; dev wallet keeps ${Number(bal - seedAmt) / 1e6}`);
for (const m of dep.FuturesMarkets as Address[]) {
  const st = await pub.readContract({ address: m, abi: mktAbi, functionName: "status" });
  if (st === 0) {
    try {
      await send(m, mktAbi, "openTrading");
      console.log(`opened trading on ${m}`);
    } catch (e) {
      console.log(`could not open ${m}: ${(e as Error).message.split("\n")[0]}`);
    }
  }
}
