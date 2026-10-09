"use client";

import Link from "next/link";
import { useState } from "react";
import { maxUint256, type Address, type PublicClient } from "viem";
import { usePublicClient } from "wagmi";
import { FuturesMarketAbi, LiquidatorAbi } from "@/abi";
import { CHAIN, USDG } from "@/config/chain";
import type { Deployment } from "@/config/deployments";
import { ErrorBox, Loading, RequireDeployment, WalletGate } from "@/components/Gates";
import { MarginPanel } from "@/components/MarginPanel";
import { Badge, Button, Card, Input, Notice, PageTitle, Row } from "@/components/ui";
import { errorMessage } from "@/lib/errors";
import { absBig, fmtAmount, fmtQvix, fmtSignedUsdWad, fmtUsd, fmtUsdWad, safeParse } from "@/lib/format";
import { useChainQuery, useWalletState } from "@/lib/hooks";
import { MARKET_STATUS, marketLabel, useMarkets, type MarketSummary } from "@/lib/protocol";
import { useTx } from "@/lib/tx";

export function Positions() {
  return <RequireDeployment>{(d) => <PositionsInner d={d} />}</RequireDeployment>;
}

type PosView = {
  id: bigint;
  market: MarketSummary;
  size: bigint;
  openNotional: bigint;
  margin: bigint;
  entryPrice: bigint;
  markPrice: bigint;
  unrealizedPnl: bigint;
  fundingOwed: bigint;
  equity: bigint;
  liquidationPrice: bigint;
  liquidatable: boolean;
  settled: boolean;
};

async function fetchPositions(c: PublicClient, markets: MarketSummary[], user: Address): Promise<PosView[]> {
  const perMarket = await Promise.all(
    markets.map(async (mk) => {
      const ids = await c.readContract({ address: mk.address, abi: FuturesMarketAbi, functionName: "positionsOf", args: [user] });
      const views = await Promise.all(
        ids.map((id) => c.readContract({ address: mk.address, abi: FuturesMarketAbi, functionName: "positionView", args: [id] })),
      );
      return views.map((v, i) => ({ id: ids[i], market: mk, ...v }));
    }),
  );
  return perMarket.flat();
}

function PositionsInner({ d }: { d: Deployment }) {
  const { address } = useWalletState();
  const markets = useMarkets(d);
  const pos = useChainQuery(["positions", address, markets.data?.map((m) => m.address).join(",")], (c) => fetchPositions(c, markets.data!, address!), {
    enabled: !!address && !!markets.data,
  });
  const [showClosed, setShowClosed] = useState(false);

  const open = (pos.data ?? []).filter((p) => !p.settled);
  const closed = (pos.data ?? []).filter((p) => p.settled);

  return (
    <div className="space-y-6">
      <PageTitle title="Positions" sub="Your QVIX futures positions across all expiries." />
      <div className="grid gap-4 lg:grid-cols-3">
        <div className="space-y-4 lg:col-span-2">
          <WalletGate message="Connect a wallet to see your positions.">
            {pos.error && <ErrorBox error={pos.error} />}
            {(markets.isLoading || pos.isLoading) && <Loading />}
            {pos.data && open.length === 0 && (
              <Notice>
                No open positions. <Link href="/trade" className="underline">Open one</Link>.
              </Notice>
            )}
            {open.map((p) => (
              <PositionCard key={`${p.market.address}-${p.id}`} p={p} />
            ))}
            {closed.length > 0 && (
              <div>
                <button className="text-sm text-muted underline" onClick={() => setShowClosed((s) => !s)}>
                  {showClosed ? "Hide" : "Show"} {closed.length} closed/settled position{closed.length > 1 ? "s" : ""}
                </button>
                {showClosed && (
                  <div className="mt-2 divide-y divide-line rounded-lg border border-line">
                    {closed.map((p) => (
                      <div key={`${p.market.address}-${p.id}`} className="flex justify-between px-3 py-2 text-sm text-muted">
                        <span>
                          {marketLabel(p.market.expiry)} · #{p.id.toString()}
                        </span>
                        <span>closed</span>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            )}
          </WalletGate>
        </div>
        <MarginPanel d={d} />
      </div>
      <Liquidations d={d} markets={markets.data ?? []} />
    </div>
  );
}

function PositionCard({ p }: { p: PosView }) {
  const { send, busy } = useTx();
  const [closeStr, setCloseStr] = useState("");
  const [marginStr, setMarginStr] = useState("");
  const isLong = p.size > 0n;
  const mk = p.market;
  const m = { address: mk.address, abi: FuturesMarketAbi } as const;
  const trading = mk.status === 1;
  const settledMarket = mk.status === 2;
  const closeSize = safeParse(closeStr, 18);
  const marginAmt = safeParse(marginStr, USDG.decimals);
  const label = `#${p.id}`;

  return (
    <Card
      title={
        <span className="flex items-center gap-2 normal-case tracking-normal">
          <span className="text-fg">{marketLabel(mk.expiry)}</span>
          <Badge tone={isLong ? "up" : "down"}>{isLong ? "LONG" : "SHORT"}</Badge>
          <span className="text-xs text-muted">{label}</span>
          {p.liquidatable && <Badge tone="down">Liquidatable</Badge>}
        </span>
      }
      right={<Badge>{MARKET_STATUS[mk.status]}</Badge>}
    >
      <div className="grid gap-4 sm:grid-cols-[1fr_auto]">
        <div className="grid grid-cols-2 gap-x-6 sm:grid-cols-3">
          <Row k="Size" v={`${fmtAmount(absBig(p.size), 18, 2)}`} />
          <Row k="Entry" v={fmtQvix(p.entryPrice)} />
          <Row k="Mark" v={fmtQvix(p.markPrice)} />
          <Row k="Notional" v={fmtUsdWad(p.openNotional)} />
          <Row k="Margin" v={fmtUsd(p.margin)} />
          <Row k="Funding PnL" v={fmtSignedUsdWad(-p.fundingOwed)} />
          <Row k="Unrealized PnL" v={<span className={p.unrealizedPnl >= 0n ? "text-up" : "text-down"}>{fmtSignedUsdWad(p.unrealizedPnl)}</span>} />
          <Row k="Equity" v={fmtSignedUsdWad(p.equity)} />
        </div>
        <div className="rounded-lg border border-down/30 bg-down/10 px-4 py-3 text-center">
          <div className="text-xs text-down">Liquidation price</div>
          <div className="num text-2xl font-bold text-down">{p.liquidationPrice > 0n ? fmtQvix(p.liquidationPrice) : "—"}</div>
          <div className="text-xs text-muted">QVIX {isLong ? "below" : "above"} this → liquidation</div>
        </div>
      </div>

      {trading && (
        <div className="mt-4 grid gap-3 md:grid-cols-2">
          <div className="space-y-2">
            <Button
              variant="danger"
              className="w-full"
              loading={busy === `Close ${label}`}
              onClick={() => send(`Close ${label}`, { ...m, functionName: "closePosition", args: [p.id, maxUint256, 0n] })}
            >
              Close full position
            </Button>
            <div className="flex gap-2">
              <Input value={closeStr} onChange={(e) => setCloseStr(e.target.value)} placeholder="contracts" className="flex-1" />
              <Button
                variant="ghost"
                disabled={!closeSize || closeSize === 0n}
                loading={busy === `Partial close ${label}`}
                onClick={() => closeSize && send(`Partial close ${label}`, { ...m, functionName: "closePosition", args: [p.id, closeSize, 0n] }).then((ok) => ok && setCloseStr(""))}
              >
                Partial close
              </Button>
            </div>
          </div>
          <div className="space-y-2">
            <Input value={marginStr} onChange={(e) => setMarginStr(e.target.value)} placeholder={`margin amount (${USDG.symbol})`} suffix={USDG.symbol} />
            <div className="grid grid-cols-2 gap-2">
              <Button
                variant="ghost"
                disabled={!marginAmt || marginAmt === 0n}
                loading={busy === `Add margin ${label}`}
                onClick={() => marginAmt && send(`Add margin ${label}`, { ...m, functionName: "addMargin", args: [p.id, marginAmt] }).then((ok) => ok && setMarginStr(""))}
              >
                Add margin
              </Button>
              <Button
                variant="ghost"
                disabled={!marginAmt || marginAmt === 0n}
                loading={busy === `Remove margin ${label}`}
                onClick={() => marginAmt && send(`Remove margin ${label}`, { ...m, functionName: "removeMargin", args: [p.id, marginAmt] }).then((ok) => ok && setMarginStr(""))}
              >
                Remove margin
              </Button>
            </div>
            <p className="text-xs text-muted">Add margin is taken from your free margin balance.</p>
          </div>
        </div>
      )}
      {settledMarket && !p.settled && (
        <div className="mt-4">
          <Notice>Market settled at {fmtQvix(mk.settlementPrice)}. Settle this position to release your payout to your margin account.</Notice>
          <Button className="mt-2" loading={busy === `Settle ${label}`} onClick={() => send(`Settle ${label}`, { ...m, functionName: "settlePosition", args: [p.id] })}>
            Settle position
          </Button>
        </div>
      )}
      {mk.status === 1 && Number(mk.expiry) * 1000 <= Date.now() && (
        <div className="mt-3">
          <Notice tone="warn">
            Market expired; awaiting settlement. Anyone can settle it from the <Link href={`/trade/${mk.index}`} className="underline">market page</Link>.
          </Notice>
        </div>
      )}
    </Card>
  );
}

function Liquidations({ d, markets }: { d: Deployment; markets: MarketSummary[] }) {
  const client = usePublicClient({ chainId: CHAIN.id }) as PublicClient | undefined;
  const { send, busy } = useTx();
  const [scanning, setScanning] = useState(false);
  const [found, setFound] = useState<{ market: MarketSummary; id: bigint }[] | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const scan = async () => {
    if (!client) return;
    setScanning(true);
    setErr(null);
    try {
      const all = await Promise.all(
        markets
          .filter((mk) => mk.status === 1)
          .map(async (mk) => {
            const next = await client.readContract({ address: mk.address, abi: FuturesMarketAbi, functionName: "nextPositionId" });
            const last = next - 1n;
            const first = last > 300n ? last - 299n : 1n;
            const ids: bigint[] = [];
            for (let i = first; i <= last; i++) ids.push(i);
            const flags = await Promise.all(
              ids.map((id) =>
                client
                  .readContract({ address: d.Liquidator, abi: LiquidatorAbi, functionName: "isLiquidatable", args: [mk.address, id] })
                  .catch(() => false),
              ),
            );
            return ids.filter((_, i) => flags[i]).map((id) => ({ market: mk, id }));
          }),
      );
      setFound(all.flat());
    } catch (e) {
      setErr(errorMessage(e));
    } finally {
      setScanning(false);
    }
  };

  return (
    <Card
      title="Liquidations"
      right={
        <Button variant="ghost" onClick={scan} loading={scanning}>
          Scan markets
        </Button>
      }
    >
      <p className="text-sm text-muted">
        Anyone can liquidate an under-margined position and earn part of the liquidation penalty. Scans the latest 300 position ids per trading market.
      </p>
      {err && <div className="mt-2"><Notice tone="error">{err}</Notice></div>}
      {found && found.length === 0 && <div className="mt-3"><Notice>No liquidatable positions found.</Notice></div>}
      {found && found.length > 0 && (
        <div className="mt-3 divide-y divide-line">
          {found.map(({ market, id }) => {
            const label = `Liquidate #${id} (${marketLabel(market.expiry)})`;
            return (
              <div key={`${market.address}-${id}`} className="flex items-center justify-between py-2 text-sm">
                <span>
                  {marketLabel(market.expiry)} · position #{id.toString()}
                </span>
                <WalletGate>
                  <Button
                    variant="danger"
                    loading={busy === label}
                    onClick={() => send(label, { address: d.Liquidator, abi: LiquidatorAbi, functionName: "liquidate", args: [market.address, id] }).then((ok) => ok && setFound((f) => f?.filter((x) => !(x.id === id && x.market.address === market.address)) ?? null))}
                  >
                    Liquidate
                  </Button>
                </WalletGate>
              </div>
            );
          })}
        </div>
      )}
    </Card>
  );
}
