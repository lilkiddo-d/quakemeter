/**
 * Robinhood Chain configuration — single source of truth.
 *
 * The data lives in ./chains.json so that both TypeScript (app, keeper) and Foundry (script/Deploy.s.sol,
 * via vm.readFile) read the exact same addresses. Every address was read from an official source and
 * checked on-chain (symbol()/description()/latestRoundData()) on 2026-10-08:
 *
 *  - Network (chain ID 4663, RPC, explorer):  https://docs.robinhood.com/chain/
 *  - WETH / USDG:                             https://docs.robinhood.com/chain/contracts
 *  - Stock tokens (canonical addresses):      on-chain asset registry used by the docs table,
 *                                             https://api.robinhood.com/rhj/assets
 *  - Stock token behaviour (18 dec, ERC-8056): https://docs.robinhood.com/chain/building-with-stock-tokens/
 *  - Chainlink price feeds:                   https://docs.robinhood.com/chain/oracles-and-price-feeds/
 *                                             https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
 *  - L2 sequencer uptime feed:                NOT published for Robinhood Chain yet
 *                                             (https://docs.chain.link/data-feeds/l2-sequencer-feeds) — the
 *                                             OracleAdapter supports it; set it through the Timelock once live.
 */
import chains from "./chains.json";

export type BasketAsset = { symbol: string; token: `0x${string}`; feed: `0x${string}` };

export type ChainConfig = {
  name: string;
  chainId: number;
  rpcUrls: string[];
  explorer: string;
  verifier: string;
  verifierUrl: string;
  gasToken: string;
  stablecoin: { symbol: string; address: `0x${string}`; decimals: number; usdFeed: `0x${string}` };
  weth: `0x${string}`;
  sequencerUptimeFeed: `0x${string}`;
  feedMaxStaleness: number;
  basket: BasketAsset[];
  sources: Record<string, string>;
  verifiedAt: string;
};

export const CHAINS = chains as unknown as Record<string, ChainConfig>;

export const ROBINHOOD_CHAIN_ID = 4663;
export const robinhood: ChainConfig = CHAINS[String(ROBINHOOD_CHAIN_ID)];
