"use client";

import type { ReactNode } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useSwitchChain } from "wagmi";
import { CHAIN } from "@/config/chain";
import { DEPLOYMENT, type Deployment } from "@/config/deployments";
import { useMounted, useWalletState } from "@/lib/hooks";
import { Button, Card } from "./ui";

export function NotDeployed() {
  return (
    <Card>
      <div className="py-10 text-center">
        <div className="text-lg font-semibold">Contracts not deployed on this network yet</div>
        <p className="mt-2 text-sm text-muted">
          No Quakemeter deployment was found for {CHAIN.name} (chain id {CHAIN.id}). Check back soon.
        </p>
      </div>
    </Card>
  );
}

/** Renders children with the deployment, or the not-deployed state. */
export function RequireDeployment({ children }: { children: (d: Deployment) => ReactNode }) {
  if (!DEPLOYMENT) return <NotDeployed />;
  return <>{children(DEPLOYMENT)}</>;
}

/** Inline gate for action areas: connect wallet / switch network. */
export function WalletGate({ children, message = "Connect a wallet to continue." }: { children: ReactNode; message?: string }) {
  const mounted = useMounted();
  const { isConnected, wrongNetwork } = useWalletState();
  const { switchChain } = useSwitchChain();
  if (!mounted) return null;
  if (!isConnected)
    return (
      <div className="flex flex-col items-center gap-3 rounded-lg border border-dashed border-line p-6 text-center text-sm text-muted">
        {message}
        <ConnectButton />
      </div>
    );
  if (wrongNetwork)
    return (
      <div className="flex flex-col items-center gap-3 rounded-lg border border-dashed border-down/40 p-6 text-center text-sm text-down">
        Your wallet is on the wrong network.
        <Button onClick={() => switchChain({ chainId: CHAIN.id })}>Switch to {CHAIN.name}</Button>
      </div>
    );
  return <>{children}</>;
}

export function Loading({ label = "Loading on-chain data…" }: { label?: string }) {
  return <div className="py-8 text-center text-sm text-muted">{label}</div>;
}

export function ErrorBox({ error }: { error: unknown }) {
  return (
    <div className="rounded-lg border border-down/40 bg-down/10 px-4 py-3 text-sm text-down">
      Could not load data from the network: {error instanceof Error ? error.message.slice(0, 160) : String(error)}
    </div>
  );
}
