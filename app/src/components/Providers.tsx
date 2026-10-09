"use client";

import { useState, type ReactNode } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { RainbowKitProvider, darkTheme } from "@rainbow-me/rainbowkit";
import { WagmiProvider } from "wagmi";
import { Toaster } from "sonner";
import { CHAIN } from "@/config/chain";
import { makeWagmiConfig } from "@/config/wagmi";

export function Providers({ children }: { children: ReactNode }) {
  const [config] = useState(() => makeWagmiConfig());
  const [queryClient] = useState(() => new QueryClient());
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider
          initialChain={CHAIN}
          theme={darkTheme({ accentColor: "#f59e0b", accentColorForeground: "#111827", borderRadius: "medium" })}
          appInfo={{ appName: "Quakemeter", learnMoreUrl: "/learn" }}
        >
          {children}
          <Toaster theme="dark" position="bottom-right" richColors closeButton />
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
