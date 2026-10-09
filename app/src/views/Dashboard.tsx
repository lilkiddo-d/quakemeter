"use client";

import Link from "next/link";
import { useMemo } from "react";
import { PriceSamplerAbi } from "@/abi";
import { BASKET } from "@/config/chain";
import type { Deployment } from "@/config/deployments";
import { RequireDeployment, ErrorBox, Loading } from "@/components/Gates";
import { QvixChart } from "@/components/QvixChart";
import { Badge, Card, Notice, Stat } from "@/components/ui";
import { fmtAmount, fmtDate, fmtDuration, fmtQvix, fmtUsdWad, toNum } from "@/lib/format";
import { safe, useChainQuery, useNow } from "@/lib/hooks";
import { MARKET_STATUS, marketLabel, nextSlotEstimate, useIndex, useMarkets } from "@/lib/protocol";
import { recentRounds } from "@/lib/rounds";

export function Dashboard() {
  return <RequireDeployment>{(d) => <DashboardInner d={d} />}</RequireDeployment>;
}

function DashboardInner({ d }: { d: Deployment }) {
  const now = useNow(1000);
  const idx = useIndex(d);
  const markets = useMarkets(d);
  const latestId = idx.data?.latestRoundId;

  const rounds = useChainQuery(["rounds", d.VolIndex, latestId?.toString()], (c) => recentRounds(c, d.VolIndex, latestId!, 500), {
    enabled: latestId !== undefined,
    refetchInterval: false,
    staleTime: Infinity,
  });

  const prices = useChainQuery(["basketPrices", d.PriceSampler, latestId?.toString()], (c) =>
    Promise.all(
      BASKET.map((_, i) => safe(c.readContract({ address: d.PriceSampler, abi: PriceSamplerAbi, functionName: "priceAt", args: [BigInt(i), 0n] }))),
    ),
  );

  const chartData = useMemo(
    () => (rounds.data ?? []).filter((r) => r.qvix > 0n).map((r) => ({ time: Number(r.timestamp), value: toNum(r.qvix) })),
    [rounds.data],
  );

  if (idx.error) return <ErrorBox error={idx.error} />;
  if (!idx.data) return <Loading />;
  const s = idx.data;
  const remaining = s.windowSize > s.returnCount ? Number(s.windowSize - s.returnCount) : 0;
  const progress = s.windowSize > 0n ? Number((s.returnCount * 10000n) / s.windowSize) / 100 : 0;
  const next = nextSlotEstimate(now);

  return (
    <div className="space-y-6">
      <div className="grid gap-4 lg:grid-cols-3">
        <Card className="lg:col-span-1">
          <div className="text-xs uppercase tracking-wide text-muted">QVIX — realized volatility index</div>
          <div className="num mt-2 text-6xl font-bold text-accent2">{s.qvix > 0n ? fmtQvix(s.qvix) : "—"}</div>
          <div className="mt-1 text-xs text-muted">Last print {fmtDate(s.ts)}</div>
          <div className="mt-4 flex flex-wrap gap-2">
            {s.ready ? <Badge tone="up">Index ready</Badge> : <Badge tone="accent">Warming up</Badge>}
            {s.marketOpen ? <Badge tone="up">US market open</Badge> : <Badge>US market closed</Badge>}
            {s.canSample && <Badge tone="accent">Sample due</Badge>}
          </div>
          {!s.ready && (
            <div className="mt-4">
              <div className="flex justify-between text-xs text-muted">
                <span>
                  Window {s.returnCount.toString()} / {s.windowSize.toString()} returns
                </span>
                <span>{progress.toFixed(1)}%</span>
              </div>
              <div className="mt-1 h-2 overflow-hidden rounded-full bg-panel2">
                <div className="h-full bg-accent" style={{ width: `${Math.min(100, progress)}%` }} />
              </div>
              <div className="mt-1 text-xs text-muted">
                ≈ {(remaining / 7).toFixed(1)} trading days until ready (7 samples per trading day)
              </div>
            </div>
          )}
          <div className="mt-4 grid grid-cols-2 gap-3">
            <Stat label="Rounds recorded" value={s.latestRoundId.toString()} />
            <Stat
              label="Next sample slot (est.)"
              value={next.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", timeZone: "America/New_York" }) + " ET"}
              sub={`in ${fmtDuration(next.getTime() / 1000 - now)}`}
            />
          </div>
        </Card>
        <Card title="QVIX history" className="lg:col-span-2" right={<span className="text-xs text-muted">last {chartData.length} prints</span>}>
          {rounds.isLoading ? (
            <Loading label="Loading history…" />
          ) : chartData.length === 0 ? (
            <div className="flex h-[300px] items-center justify-center text-sm text-muted">No QVIX prints yet.</div>
          ) : (
            <QvixChart data={chartData} />
          )}
        </Card>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        <Card title="Basket (equal weight)">
          <div className="divide-y divide-line">
            {BASKET.map((a, i) => {
              const p = prices.data?.[i];
              return (
                <div key={a.symbol} className="flex items-center justify-between py-2 text-sm">
                  <span className="font-semibold">{a.symbol}</span>
                  <span className="num">{p && p[0] > 0n ? fmtUsdWad(p[0]) : "—"}</span>
                  <span className="hidden text-xs text-muted sm:inline">{p && p[1] > 0n ? fmtDate(p[1]) : "no sample"}</span>
                </div>
              );
            })}
          </div>
          <p className="mt-3 text-xs text-muted">Last sampled prices from the on-chain PriceSampler (Chainlink feeds).</p>
        </Card>

        <Card title="Futures expiries">
          {markets.error && <ErrorBox error={markets.error} />}
          {!markets.data && !markets.error && <Loading />}
          {markets.data?.length === 0 && <Notice>No futures markets deployed.</Notice>}
          <div className="divide-y divide-line">
            {markets.data?.map((m) => {
              const expired = Number(m.expiry) <= now;
              return (
                <Link key={m.address} href={`/trade/${m.index}`} className="flex items-center justify-between gap-2 py-2 text-sm hover:bg-panel2/50">
                  <div>
                    <div className="font-semibold">{marketLabel(m.expiry)}</div>
                    <div className="text-xs text-muted">{fmtDate(m.expiry)}</div>
                  </div>
                  <div className="text-right">
                    <div className="num">
                      {m.status === 2 ? `Settled ${fmtQvix(m.settlementPrice)}` : m.mark !== undefined && m.status === 1 ? fmtQvix(m.mark) : "—"}
                    </div>
                    <Badge tone={m.status === 1 ? (expired ? "accent" : "up") : m.status === 2 ? "muted" : "accent"}>
                      {m.status === 1 && expired ? "Awaiting settlement" : MARKET_STATUS[m.status]}
                    </Badge>
                  </div>
                </Link>
              );
            })}
          </div>
          {markets.data && markets.data.length > 0 && (
            <p className="mt-3 text-xs text-muted">
              Open interest shown on each market page. OI long/short in contracts: {markets.data.map((m) => `${fmtAmount(m.longSize, 18, 2)}/${fmtAmount(m.shortSize, 18, 2)}`).join(" · ")}
            </p>
          )}
        </Card>
      </div>
    </div>
  );
}
