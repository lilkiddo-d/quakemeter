"use client";

import { useCallback, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import type { Abi, Address, ContractFunctionArgs, ContractFunctionName, PublicClient } from "viem";
import { useAccount, usePublicClient, useSwitchChain, useWriteContract } from "wagmi";
import { toast } from "sonner";
import { ERC20Abi } from "@/abi";
import { CHAIN, explorerTx } from "@/config/chain";
import { errorMessage } from "./errors";

type WriteFn<abi extends Abi> = ContractFunctionName<abi, "nonpayable" | "payable">;

export type TxRequest<abi extends Abi, fn extends WriteFn<abi>> = {
  address: Address;
  abi: abi;
  functionName: fn;
  args: ContractFunctionArgs<abi, "nonpayable" | "payable", fn>;
};

/** Simulate -> send -> wait for receipt, with toasts and cache invalidation. */
export function useTx() {
  const client = usePublicClient({ chainId: CHAIN.id }) as PublicClient | undefined;
  const { address, chainId } = useAccount();
  const { writeContractAsync } = useWriteContract();
  const { switchChainAsync } = useSwitchChain();
  const qc = useQueryClient();
  const [busy, setBusy] = useState<string | null>(null);

  const send = useCallback(
    async <const abi extends Abi, fn extends WriteFn<abi>>(label: string, req: TxRequest<abi, fn>): Promise<boolean> => {
      if (!client || !address) {
        toast.error("Connect a wallet first");
        return false;
      }
      const id = toast.loading(`${label}…`, { description: "Confirm in your wallet" });
      setBusy(label);
      try {
        if (chainId !== CHAIN.id) await switchChainAsync({ chainId: CHAIN.id });
        // Simulate first so reverts surface with a decoded custom-error name before the wallet prompt.
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const { request } = await client.simulateContract({ ...(req as any), account: address });
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const hash = await writeContractAsync({ ...(request as any), chainId: CHAIN.id });
        const link = explorerTx(hash);
        const action = link ? { label: "Explorer", onClick: () => window.open(link, "_blank", "noopener") } : undefined;
        toast.loading(`${label}: pending`, { id, description: `${hash.slice(0, 18)}…`, action });
        const receipt = await client.waitForTransactionReceipt({ hash });
        if (receipt.status !== "success") throw new Error("Transaction reverted on-chain");
        toast.success(`${label}: confirmed`, { id, description: `Block ${receipt.blockNumber}`, action });
        await qc.invalidateQueries({ queryKey: ["chain"] });
        return true;
      } catch (e) {
        toast.error(`${label} failed`, { id, description: errorMessage(e) });
        return false;
      } finally {
        setBusy(null);
      }
    },
    [client, address, chainId, switchChainAsync, writeContractAsync, qc],
  );

  /** Approves exactly `amount` (never unlimited) if the current allowance is lower. */
  const ensureAllowance = useCallback(
    async (token: Address, spender: Address, amount: bigint, symbol = "token"): Promise<boolean> => {
      if (!client || !address) return false;
      try {
        const current = await client.readContract({
          address: token,
          abi: ERC20Abi,
          functionName: "allowance",
          args: [address, spender],
        });
        if (current >= amount) return true;
      } catch (e) {
        toast.error("Could not read allowance", { description: errorMessage(e) });
        return false;
      }
      return send(`Approve ${symbol}`, { address: token, abi: ERC20Abi, functionName: "approve", args: [spender, amount] });
    },
    [client, address, send],
  );

  return { send, ensureAllowance, busy };
}
