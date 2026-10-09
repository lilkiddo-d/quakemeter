"use client";

import Link from "next/link";
import { useState } from "react";
import { formatUnits, type PublicClient } from "viem";
import { ERC20Abi, InsuranceFundAbi, LPVaultAbi } from "@/abi";
import { USDG } from "@/config/chain";
import { isZero, type Deployment } from "@/config/deployments";
import { ErrorBox, Loading, RequireDeployment, WalletGate } from "@/components/Gates";
import { Button, Card, Input, Notice, PageTitle, Row, Segmented, Stat } from "@/components/ui";
import { fmtAmount, fmtDate, fmtDuration, fmtUsd, safeParse, toNum } from "@/lib/format";
import { safe, useChainQuery, useNow, useWalletState } from "@/lib/hooks";
import { useTx } from "@/lib/tx";

const SHARE_DECIMALS = 12;

export function Vault() {
  return <RequireDeployment>{(d) => <VaultInner d={d} />}</RequireDeployment>;
}

async function fetchVault(c: PublicClient, d: Deployment) {
  const v = { address: d.LPVault, abi: LPVaultAbi } as const;
  const [totalAssets, sharePrice, liabilities, reserve, free, lock, totalSupply, paused, insurance] = await Promise.all([
    safe(c.readContract({ ...v, functionName: "totalAssets" })),
    safe(c.readContract({ ...v, functionName: "convertToAssets", args: [10n ** BigInt(SHARE_DECIMALS)] })),
    c.readContract({ ...v, functionName: "traderLiabilities" }),
    c.readContract({ ...v, functionName: "requiredReserve" }),
    safe(c.readContract({ ...v, functionName: "freeLiquidity" })),
    c.readContract({ ...v, functionName: "depositLock" }),
    c.readContract({ ...v, functionName: "totalSupply" }),
    c.readContract({ ...v, functionName: "paused" }),
    isZero(d.InsuranceFund) ? Promise.resolve(undefined) : safe(c.readContract({ address: d.InsuranceFund, abi: InsuranceFundAbi, functionName: "balance" })),
  ]);
  return { totalAssets, sharePrice, liabilities, reserve, free, lock, totalSupply, paused, insurance };
}

function VaultInner({ d }: { d: Deployment }) {
  const now = useNow(1000);
  const { address } = useWalletState();
  const q = useChainQuery(["vault", d.LPVault], (c) => fetchVault(c, d));
  const user = useChainQuery(
    ["vaultUser", d.LPVault, address],
    async (c) => {
      const v = { address: d.LPVault, abi: LPVaultAbi } as const;
      const [shares, maxWithdraw, maxRedeem, lastDepositAt, wallet] = await Promise.all([
        c.readContract({ ...v, functionName: "balanceOf", args: [address!] }),
        c.readContract({ ...v, functionName: "maxWithdraw", args: [address!] }),
        c.readContract({ ...v, functionName: "maxRedeem", args: [address!] }),
        c.readContract({ ...v, functionName: "lastDepositAt", args: [address!] }),
        c.readContract({ address: USDG.address, abi: ERC20Abi, functionName: "balanceOf", args: [address!] }),
      ]);
      return { shares, maxWithdraw, maxRedeem, lastDepositAt, wallet };
    },
    { enabled: !!address },
  );
  const [mode, setMode] = useState<"deposit" | "withdraw" | "redeem">("deposit");
  const [amount, setAmount] = useState("");
  const { send, ensureAllowance, busy } = useTx();

  if (q.error) return <ErrorBox error={q.error} />;
  if (!q.data) return <Loading />;
  const v = q.data;
  const u = user.data;
  const unlockAt = u && u.lastDepositAt > 0n ? Number(u.lastDepositAt + v.lock) : 0;
  const locked = unlockAt > now;
  const decimals = mode === "redeem" ? SHARE_DECIMALS : USDG.decimals;
  const parsed = safeParse(amount, decimals);
  const max = mode === "deposit" ? u?.wallet : mode === "withdraw" ? u?.maxWithdraw : u?.maxRedeem;
  const userAssets = u && v.sharePrice !== undefined ? (u.shares * v.sharePrice) / 10n ** BigInt(SHARE_DECIMALS) : undefined;
  const utilization = v.totalAssets && v.totalAssets > 0n ? toNum(v.reserve, USDG.decimals) / toNum(v.totalAssets, USDG.decimals) : NaN;

  const submit = async () => {
    if (!parsed || !address) return;
    let ok = false;
    if (mode === "deposit") {
      if (!(await ensureAllowance(USDG.address, d.LPVault, parsed, USDG.symbol))) return;
      ok = await send(`Deposit ${amount} ${USDG.symbol} to vault`, { address: d.LPVault, abi: LPVaultAbi, functionName: "deposit", args: [parsed, address] });
    } else if (mode === "withdraw") {
      ok = await send(`Withdraw ${amount} ${USDG.symbol}`, { address: d.LPVault, abi: LPVaultAbi, functionName: "withdraw", args: [parsed, address, address] });
    } else {
      ok = await send(`Redeem ${amount} shares`, { address: d.LPVault, abi: LPVaultAbi, functionName: "redeem", args: [parsed, address, address] });
    }
    if (ok) setAmount("");
  };

  return (
    <div className="space-y-6">
      <PageTitle title="LP Vault" sub="Provide USDG liquidity. The vault is the counterparty to every futures trader and earns trading fees." />
      {v.paused && <Notice tone="warn">The vault is currently paused.</Notice>}
      <Card>
        <div className="grid grid-cols-2 gap-4 md:grid-cols-3 lg:grid-cols-6">
          <Stat label="TVL" value={fmtUsd(v.totalAssets)} tone="accent" />
          <Stat label="Share price" value={v.sharePrice !== undefined ? `${toNum(v.sharePrice, USDG.decimals).toFixed(6)}` : "—"} />
          <Stat label="Trader liabilities" value={fmtUsd(v.liabilities)} />
          <Stat label="Required reserve" value={fmtUsd(v.reserve)} sub={Number.isFinite(utilization) ? `${(utilization * 100).toFixed(1)}% of TVL` : undefined} />
          <Stat label="Free liquidity" value={fmtUsd(v.free)} sub="withdrawable by LPs" />
          <Stat label="Insurance fund" value={fmtUsd(v.insurance)} />
        </div>
      </Card>
      <div className="grid gap-4 lg:grid-cols-3">
        <Card title="Your position" className="lg:col-span-1">
          <WalletGate message="Connect a wallet to provide liquidity.">
            <Row k="Shares" v={fmtAmount(u?.shares, SHARE_DECIMALS, 4)} />
            <Row k="Value" v={fmtUsd(userAssets)} />
            <Row k="Max withdraw" v={fmtUsd(u?.maxWithdraw)} />
            <Row k="Max redeem" v={`${fmtAmount(u?.maxRedeem, SHARE_DECIMALS, 4)} shares`} />
            <Row k="Last deposit" v={u && u.lastDepositAt > 0n ? fmtDate(u.lastDepositAt) : "—"} />
            <Row k="Deposit lock" v={fmtDuration(Number(v.lock))} />
            {locked && <Row k="Unlocks in" v={<span className="text-accent2">{fmtDuration(unlockAt - now)}</span>} />}
          </WalletGate>
        </Card>
        <Card title="Deposit / withdraw" className="lg:col-span-2">
          <WalletGate message="Connect a wallet to provide liquidity.">
            <div className="space-y-3">
              <Segmented
                value={mode}
                onChange={(m) => {
                  setMode(m);
                  setAmount("");
                }}
                options={[
                  { value: "deposit", label: "Deposit" },
                  { value: "withdraw", label: "Withdraw" },
                  { value: "redeem", label: "Redeem shares" },
                ]}
              />
              <Input
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
                placeholder="0.00"
                suffix={
                  <button type="button" className="text-accent2" onClick={() => max !== undefined && setAmount(formatUnits(max, decimals))}>
                    MAX {mode === "redeem" ? "shares" : USDG.symbol}
                  </button>
                }
                hint={
                  mode === "deposit"
                    ? `Wallet: ${fmtUsd(u?.wallet)}. Deposits are locked for ${fmtDuration(Number(v.lock))} (re-depositing resets the lock).`
                    : "Withdrawals are limited by free liquidity (assets not reserved against open trader positions)."
                }
              />
              {locked && mode !== "deposit" && <Notice tone="warn">Your deposit is locked for another {fmtDuration(unlockAt - now)}.</Notice>}
              <Button className="w-full" disabled={!parsed || parsed === 0n || (max !== undefined && parsed > max)} loading={!!busy} onClick={submit}>
                {mode === "deposit" ? "Approve & deposit" : mode === "withdraw" ? "Withdraw" : "Redeem"}
              </Button>
            </div>
          </WalletGate>
        </Card>
      </div>
      <Card title="LP risk">
        <ul className="list-disc space-y-1 pl-5 text-sm text-muted">
          <li>The vault takes the opposite side of net trader exposure. When traders win (e.g. volatility spikes and longs dominate), the vault pays their profit and the share price falls.</li>
          <li>Income comes from trading fees and liquidation penalties; it may not compensate for trader gains.</li>
          <li>Part of the vault is reserved against open interest and cannot be withdrawn until positions close; the deposit lock also applies.</li>
          <li>The insurance fund absorbs bad debt first, but may be insufficient in extreme moves. Smart-contract and oracle risk apply.</li>
        </ul>
        <p className="mt-2 text-xs text-muted">
          Read the full <Link href="/risk" className="underline">risk disclosure</Link>.
        </p>
      </Card>
    </div>
  );
}
