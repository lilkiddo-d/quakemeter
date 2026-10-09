import { connectorsForWallets, getDefaultConfig } from "@rainbow-me/rainbowkit";
import { injectedWallet } from "@rainbow-me/rainbowkit/wallets";
import { createConfig, http, type Config } from "wagmi";
import type { Chain, Transport } from "viem";
import { CHAIN, RPC_URL } from "./chain";
import { WALLETCONNECT_PROJECT_ID } from "./env";

const APP_NAME = "Quakemeter";

// JSON-RPC batching (no multicall3): many eth_calls per HTTP request.
const transport = http(RPC_URL, { batch: { batchSize: 100, wait: 16 }, retryCount: 1 });

export function makeWagmiConfig(): Config {
  if (WALLETCONNECT_PROJECT_ID) {
    return getDefaultConfig({
      appName: APP_NAME,
      projectId: WALLETCONNECT_PROJECT_ID,
      chains: [CHAIN as Chain],
      transports: { [CHAIN.id]: transport } as Record<number, Transport>,
      ssr: true,
      batch: { multicall: false },
    });
  }
  // No WalletConnect project id: injected (browser extension) wallets only.
  const connectors = connectorsForWallets([{ groupName: "Browser wallets", wallets: [injectedWallet] }], {
    appName: APP_NAME,
    projectId: "unused",
  });
  return createConfig({
    connectors,
    chains: [CHAIN as Chain],
    transports: { [CHAIN.id]: transport } as Record<number, Transport>,
    ssr: true,
    batch: { multicall: false },
  });
}
