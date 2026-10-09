"use client";

import { useState } from "react";
import { formatUnits, type Address, type PublicClient } from "viem";
import { ERC20Abi, ProjectTokenHooksAbi } from "@/abi";
import { USDG } from "@/config/chain";
import { isZero, type Deployment } from "@/config/deployments";
import { PROJECT_TOKEN } from "@/config/env";
import { ErrorBox, Loading, RequireDeployment, WalletGate } from "@/components/Gates";
import { AddrLink, Button, Card, Input, Notice, PageTitle, Row, Segmented, Stat } from "@/components/ui";
import { cx } from "@/components/ui";
import { fmtAmount, fmtBps, fmtDate, fmtDuration, fmtUsd, safeParse } from "@/lib/format";
import { safe, useChainQuery, useNow, useWalletState } from "@/lib/hooks";
import { useTx } from "@/lib/tx";

export function Stake() {
  return <RequireDeployment>{(d) => (isZero(d.ProjectTokenHooks) ? <Notice>Staking contract not deployed.</Notice> : <StakeInner d={d} token={PROJECT_TOKEN!} />)}</RequireDeployment>;
}

async function fetchStake(c: PublicClient, d: Deployment, token: Address) {
  const h = { address: d.ProjectTokenHooks, abi: ProjectTokenHooksAbi } as const;
  const [active, onchainToken, tiers, totalStaked, cooldown, paused, symbol, decimals] = await Promise.all([
    c.readContract({ ...h, functionName: "isActive" }),
    c.readContract({ ...h, functionName: "projectToken" }),
    c.readContract({ ...h, functionName: "tiers" }),
    c.readContract({ ...h, functionName: "totalStaked" }),
    c.readContract({ ...h, functionName: "unstakeCooldown" }),
    c.readContract({ ...h, functionName: "paused" }),
    safe(c.readContract({ address: token, abi: ERC20Abi, functionName: "symbol" })),
    safe(c.readContract({ address: token, abi: ERC20Abi, functionName: "decimals" })),
  ]);
  const rewardToken = await safe(c.readContract({ ...h, functionName: "rewardToken" }));
  const [rSymbol, rDecimals] = rewardToken
    ? await Promise.all([
        safe(c.readContract({ address: rewardToken, abi: ERC20Abi, functionName: "symbol" })),
        safe(c.readContract({ address: rewardToken, abi: ERC20Abi, functionName: "decimals" })),
      ])
    : [undefined, undefined];
  return {
    active,
    onchainToken,
    thresholds: tiers[0],
    discounts: tiers[1],
    totalStaked,
    cooldown,
    paused,
    symbol: symbol ?? "QUAK",
    decimals: decimals ?? 18,
    rewardSymbol: rSymbol ?? USDG.symbol,
    rewardDecimals: rDecimals ?? USDG.decimals,
  };
}

function StakeInner({ d, token }: { d: Deployment; token: Address }) {
  const now = useNow(1000);
  const { address } = useWalletState();
  const q = useChainQuery(["stake", d.ProjectTokenHooks, token], (c) => fetchStake(c, d, token));
  const user = useChainQuery(
    ["stakeUser", d.ProjectTokenHooks, token, address],
    async (c) => {
      const h = { address: d.ProjectTokenHooks, abi: ProjectTokenHooksAbi } as const;
      const [staked, pending, unlockAt, earned, discount, wallet] = await Promise.all([
        c.readContract({ ...h, functionName: "stakedOf", args: [address!] }),
        c.readContract({ ...h, functionName: "pendingUnstake", args: [address!] }),
        c.readContract({ ...h, functionName: "unstakeUnlockAt", args: [address!] }),
        c.readContract({ ...h, functionName: "earned", args: [address!] }),
        c.readContract({ ...h, functionName: "feeDiscountBps", args: [address!] }),
        safe(c.readContract({ address: token, abi: ERC20Abi, functionName: "balanceOf", args: [address!] })),
      ]);
      return { staked, pending, unlockAt, earned, discount, wallet };
    },
    { enabled: !!address },
  );
  const [mode, setMode] = useState<"stake" | "unstake">("stake");
  const [amount, setAmount] = useState("");
  const { send, ensureAllowance, busy } = useTx();

  if (q.error) return <ErrorBox error={q.error} />;
  if (!q.data) return <Loading />;
  const s = q.data;
  const u = user.data;
  const h = { address: d.ProjectTokenHooks, abi: ProjectTokenHooksAbi } as const;
  const parsed = safeParse(amount, s.decimals);
  const max = mode === "stake" ? u?.wallet : u?.staked;
  const mismatch = s.active && s.onchainToken.toLowerCase() !== token.toLowerCase();
  const coolingDown = !!u && u.pending > 0n && Number(u.unlockAt) > now;

  const submit = async () => {
    if (!parsed) return;
    let ok = false;
    if (mode === "stake") {
      if (!(await ensureAllowance(token, d.ProjectTokenHooks, parsed, s.symbol))) return;
      ok = await send(`Stake ${amount} ${s.symbol}`, { ...h, functionName: "stake", args: [parsed] });
    } else {
      ok = await send(`Request unstake ${amount} ${s.symbol}`, { ...h, functionName: "requestUnstake", args: [parsed] });
    }
    if (ok) setAmount("");
  };

  return (
    <div className="space-y-6">
      <PageTitle title={`Stake ${s.symbol}`} sub="Stake to earn a share of protocol fees and unlock trading-fee discounts." />
      {!s.active && <Notice tone="warn">Token not yet activated by governance. Staking opens once the Timelock sets the project token.</Notice>}
      {mismatch && (
        <Notice tone="error">
          The configured token (<AddrLink address={token} />) differs from the on-chain project token (<AddrLink address={s.onchainToken} />). Check the app configuration.
        </Notice>
      )}
      {s.paused && <Notice tone="warn">Staking is paused.</Notice>}
      <Card>
        <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
          <Stat label="Total staked" value={`${fmtAmount(s.totalStaked, s.decimals, 2)} ${s.symbol}`} />
          <Stat label="Unstake cooldown" value={fmtDuration(Number(s.cooldown))} />
          <Stat label="Your fee discount" value={fmtBps(u?.discount)} tone="accent" />
          <Stat label="Earned" value={fmtAmount(u?.earned, s.rewardDecimals, 4)} sub={s.rewardSymbol} />
        </div>
      </Card>
      <div className="grid gap-4 lg:grid-cols-3">
        <Card title="Fee-discount tiers">
          {s.thresholds.length === 0 && <p className="text-sm text-muted">No tiers configured.</p>}
          <div className="divide-y divide-line">
            {s.thresholds.map((t, i) => {
              const reached = !!u && u.staked >= t * 10n ** BigInt(s.decimals);
              return (
                <div key={i} className={cx("flex justify-between py-2 text-sm", reached && "text-accent2")}>
                  <span>
                    ≥ {t.toLocaleString()} {s.symbol}
                  </span>
                  <span className="num">−{fmtBps(s.discounts[i])} fees</span>
                </div>
              );
            })}
          </div>
        </Card>
        <Card title="Your stake" className="lg:col-span-2">
          <WalletGate message="Connect a wallet to stake.">
            <div className="grid gap-4 md:grid-cols-2">
              <div>
                <Row k="Staked" v={`${fmtAmount(u?.staked, s.decimals, 4)} ${s.symbol}`} />
                <Row k="Wallet" v={`${fmtAmount(u?.wallet, s.decimals, 4)} ${s.symbol}`} />
                <Row k="Pending unstake" v={`${fmtAmount(u?.pending, s.decimals, 4)} ${s.symbol}`} />
                {u && u.pending > 0n && <Row k="Unlocks" v={coolingDown ? `in ${fmtDuration(Number(u.unlockAt) - now)}` : fmtDate(u.unlockAt)} />}
                <div className="mt-3 grid grid-cols-2 gap-2">
                  <Button
                    variant="ghost"
                    disabled={!u || u.pending === 0n || coolingDown}
                    loading={busy === "Withdraw unstaked"}
                    onClick={() => send("Withdraw unstaked", { ...h, functionName: "withdrawUnstaked", args: [] })}
                  >
                    Withdraw unstaked
                  </Button>
                  <Button
                    variant="ghost"
                    disabled={!u || u.earned === 0n}
                    loading={busy === "Claim rewards"}
                    onClick={() => send("Claim rewards", { ...h, functionName: "claim", args: [] })}
                  >
                    Claim rewards
                  </Button>
                </div>
              </div>
              <div className="space-y-3">
                <Segmented value={mode} onChange={setMode} options={[{ value: "stake", label: "Stake" }, { value: "unstake", label: "Unstake" }]} />
                <Input
                  value={amount}
                  onChange={(e) => setAmount(e.target.value)}
                  placeholder="0.0"
                  suffix={
                    <button type="button" className="text-accent2" onClick={() => max !== undefined && setAmount(formatUnits(max, s.decimals))}>
                      MAX
                    </button>
                  }
                  hint={mode === "unstake" ? `Unstaking starts a ${fmtDuration(Number(s.cooldown))} cooldown (new requests reset it).` : undefined}
                />
                <Button className="w-full" disabled={!s.active || !parsed || parsed === 0n || (max !== undefined && parsed > max)} loading={!!busy} onClick={submit}>
                  {mode === "stake" ? "Approve & stake" : "Request unstake"}
                </Button>
              </div>
            </div>
          </WalletGate>
        </Card>
      </div>
    </div>
  );
}
