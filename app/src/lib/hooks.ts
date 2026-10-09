"use client";

import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import type { PublicClient } from "viem";
import { useAccount, usePublicClient } from "wagmi";
import { CHAIN } from "@/config/chain";

export const REFRESH_MS = 30_000;

/** Parallel viem reads (JSON-RPC batched by the transport, no multicall) wrapped in react-query. */
export function useChainQuery<T>(
  key: readonly unknown[],
  fn: (client: PublicClient) => Promise<T>,
  opts: { enabled?: boolean; refetchInterval?: number | false; staleTime?: number } = {},
) {
  const client = usePublicClient({ chainId: CHAIN.id }) as PublicClient | undefined;
  return useQuery({
    queryKey: ["chain", CHAIN.id, ...key],
    queryFn: () => fn(client as PublicClient),
    enabled: !!client && (opts.enabled ?? true),
    refetchInterval: opts.refetchInterval ?? REFRESH_MS,
    staleTime: opts.staleTime ?? 10_000,
    retry: 1,
  });
}

/** Resolves to undefined instead of throwing (e.g. vAMM mark before trading opens). */
export async function safe<T>(p: Promise<T>): Promise<T | undefined> {
  try {
    return await p;
  } catch {
    return undefined;
  }
}

export function useNow(intervalMs = 1000) {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);
  return now;
}

/** Wallet state relative to the configured chain. */
export function useWalletState() {
  const { address, isConnected, chainId } = useAccount();
  return { address, isConnected, wrongNetwork: isConnected && chainId !== CHAIN.id };
}

export function useMounted() {
  const [m, setM] = useState(false);
  useEffect(() => setM(true), []);
  return m;
}
