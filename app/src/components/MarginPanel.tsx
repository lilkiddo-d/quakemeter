"use client";

import { useState } from "react";
import { formatUnits } from "viem";
import { ERC20Abi, MarginAccountAbi } from "@/abi";
import { USDG } from "@/config/chain";
import type { Deployment } from "@/config/deployments";
import { fmtUsd, safeParse } from "@/lib/format";
import { useChainQuery, useWalletState } from "@/lib/hooks";
import { useTx } from "@/lib/tx";
import { WalletGate } from "./Gates";
import { Button, Card, Input, Row, Segmented } from "./ui";

export function useMarginBalances(d: Deployment) {
  const { address } = useWalletState();
  return useChainQuery(
    ["margin", d.MarginAccount, address],
    async (c) => {
      const [free, wallet] = await Promise.all([
        c.readContract({ address: d.MarginAccount, abi: MarginAccountAbi, functionName: "freeBalance", args: [address!] }),
        c.readContract({ address: USDG.address, abi: ERC20Abi, functionName: "balanceOf", args: [address!] }),
      ]);
      return { free, wallet };
    },
    { enabled: !!address },
  );
}

export function MarginPanel({ d }: { d: Deployment }) {
  const [mode, setMode] = useState<"deposit" | "withdraw">("deposit");
  const [amount, setAmount] = useState("");
  const bal = useMarginBalances(d);
  const { send, ensureAllowance, busy } = useTx();
  const parsed = safeParse(amount, USDG.decimals);
  const max = mode === "deposit" ? bal.data?.wallet : bal.data?.free;

  const submit = async () => {
    if (!parsed) return;
    if (mode === "deposit") {
      if (!(await ensureAllowance(USDG.address, d.MarginAccount, parsed, USDG.symbol))) return;
      if (await send(`Deposit ${amount} ${USDG.symbol}`, { address: d.MarginAccount, abi: MarginAccountAbi, functionName: "deposit", args: [parsed] })) setAmount("");
    } else {
      if (await send(`Withdraw ${amount} ${USDG.symbol}`, { address: d.MarginAccount, abi: MarginAccountAbi, functionName: "withdraw", args: [parsed] })) setAmount("");
    }
  };

  return (
    <Card title="Margin account">
      <WalletGate message="Connect a wallet to manage margin.">
        <Row k="Free margin" v={fmtUsd(bal.data?.free)} />
        <Row k={`Wallet ${USDG.symbol}`} v={fmtUsd(bal.data?.wallet)} />
        <div className="mt-3 space-y-3">
          <Segmented value={mode} onChange={setMode} options={[{ value: "deposit", label: "Deposit" }, { value: "withdraw", label: "Withdraw" }]} />
          <Input
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder="0.00"
            suffix={
              <button type="button" className="text-accent2" onClick={() => max !== undefined && setAmount(formatUnits(max, USDG.decimals))}>
                MAX {USDG.symbol}
              </button>
            }
          />
          <Button className="w-full" disabled={!parsed || parsed === 0n || (max !== undefined && parsed > max)} loading={!!busy} onClick={submit}>
            {mode === "deposit" ? "Approve & deposit" : "Withdraw"}
          </Button>
          <p className="text-xs text-muted">Free margin is used when opening positions. Margin locked in open positions is not withdrawable.</p>
        </div>
      </WalletGate>
    </Card>
  );
}
