import { defineChain } from "viem";
import chainsJson from "@config/chains.json";
import type { ChainConfig } from "@config/chains";
import { CHAIN_ID, RPC_OVERRIDE } from "./env";

/** Robinhood Chain config from the repo-root single source of truth (config/chains.json). */
export const NETWORK: ChainConfig = (chainsJson as unknown as Record<string, ChainConfig>)["4663"];

export const USDG = {
  address: NETWORK.stablecoin.address,
  symbol: NETWORK.stablecoin.symbol,
  decimals: NETWORK.stablecoin.decimals,
} as const;

/** Basket order equals on-chain PriceSampler.assets() order. */
export const BASKET = NETWORK.basket;

const mainnet = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [NETWORK.rpcUrls[0]] } },
  blockExplorers: { default: { name: "Blockscout", url: NETWORK.explorer } },
  // multicall3 intentionally NOT configured (deployment on 4663 unverified); reads use JSON-RPC batching.
});

const localFork = defineChain({
  id: 31337,
  name: "Robinhood Chain (local fork)",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
  testnet: true,
});

export const CHAIN = CHAIN_ID === 31337 ? localFork : mainnet;
export const RPC_URL = RPC_OVERRIDE ?? CHAIN.rpcUrls.default.http[0];
/** Explorer only for mainnet; a local fork has none. */
export const EXPLORER: string | undefined = CHAIN_ID === 4663 ? NETWORK.explorer : undefined;

export function explorerAddress(addr: string) {
  return EXPLORER ? `${EXPLORER}/address/${addr}` : undefined;
}
export function explorerTx(hash: string) {
  return EXPLORER ? `${EXPLORER}/tx/${hash}` : undefined;
}
