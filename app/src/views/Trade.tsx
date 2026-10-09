"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { formatUnits, isAddress, getAddress, type Address, type PublicClient } from "viem";
import { usePublicClient } from "wagmi";
import { toast } from "sonner";
import { FeeCollectorAbi, FuturesMarketAbi, VAMMAbi, VolIndexAbi } from "@/abi";
import { CHAIN, USDG } from "@/config/chain";
import { isZero, type Deployment } from "@/config/deployments";
import { TOKEN_FEATURES } from "@/config/env";
import { ErrorBox, Loading, RequireDeployment, WalletGate } from "@/components/Gates";
import { MarginPanel, useMarginBalances } from "@/components/MarginPanel";
import { AddrLink, Badge, Button, Card, Input, Notice, PageTitle, Row, Segmented, Stat } from "@/components/ui";
import { BPS, WAD, absBig, fmtAmount, fmtBps, fmtDate, fmtDuration, fmtPct, fmtQvix, fmtUsd, fmtUsdWad, safeParse, toNum } from "@/lib/format";
import { safe, useChainQuery, useNow, useWalletState } from "@/lib/hooks";
import { MARKET_STATUS, marketLabel, useMarkets } from "@/lib/protocol";
import { lastRoundAtOrBefore } from "@/lib/rounds";
import { useTx } from "@/lib/tx";

export function TradeIndex() {
  return <RequireDeployment>{(d) => <TradeIndexInner d={d} />}</RequireDeployment>;
}

function TradeIndexInner({ d }: { d: Deployment }) {
  const markets = useMarkets(d);
  const now = useNow(10_000);
  return (
    <div>
      <PageTitle title="Trade QVIX futures" sub="1 contract = $1 per QVIX point. Long = bet on chaos, short = bet on calm." />
      {markets.error && <ErrorBox error={markets.error} />}
      {!markets.data && !markets.error && <Loading />}
      {markets.data?.length === 0 && <Notice>No futures markets deployed yet.</Notice>}
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {markets.data?.map((m) => (
          <Link key={m.address} href={`/trade/${m.index}`} className="rounded-xl border border-line bg-panel p-5 hover:border-accent">
            <div className="flex items-center justify-between">
              <span className="font-semibold">{marketLabel(m.expiry)}</span>
              <Badge tone={m.status === 1 ? "up" : "muted"}>{MARKET_STATUS[m.status]}</Badge>
            </div>
            <div className="num mt-3 text-3xl font-bold">{m.status === 2 ? fmtQvix(m.settlementPrice) : m.status === 1 ? fmtQvix(m.mark) : "—"}</div>
            <div className="mt-1 text-xs text-muted">
              Expiry {fmtDate(m.expiry)} {Number(m.expiry) > now ? `(in ${fmtDuration(Number(m.expiry) - now)})` : ""}
            </div>
          </Link>
        ))}
      </div>
    </div>
  );
}

export function TradeMarket({ market }: { market: string }) {
  return <RequireDeployment>{(d) => <TradeResolve d={d} market={market} />}</RequireDeployment>;
}

function TradeResolve({ d, market }: { d: Deployment; market: string }) {
  let addr: Address | undefined;
  let index = -1;
  if (/^\d+$/.test(market)) {
    index = Number(market);
    addr = d.FuturesMarkets[index];
  } else if (isAddress(market)) {
    const a = getAddress(market);
    index = d.FuturesMarkets.indexOf(a);
    if (index >= 0) addr = a;
  }
  if (!addr)
    return (
      <Notice tone="error">
        Unknown market “{market}”. Only markets from the official deployment are listed. <Link href="/trade" className="underline">Back to markets</Link>
      </Notice>
    );
  return <TradeInner d={d} market={addr} index={index} />;
}

async function fetchMarketFull(c: PublicClient, d: Deployment, market: Address) {
  const m = { address: market, abi: FuturesMarketAbi } as const;
  const [status, expiry, mark, ema, cumFunding, longSize, shortSize, params, vamm, settlementPrice, scale, paused, latest, ready] =
    await Promise.all([
      c.readContract({ ...m, functionName: "status" }),
      c.readContract({ ...m, functionName: "expiry" }),
      safe(c.readContract({ ...m, functionName: "markPrice" })),
      safe(c.readContract({ ...m, functionName: "emaMarkPrice" })),
      c.readContract({ ...m, functionName: "cumFunding" }),
      c.readContract({ ...m, functionName: "longSize" }),
      c.readContract({ ...m, functionName: "shortSize" }),
      c.readContract({ ...m, functionName: "getParams" }),
      c.readContract({ ...m, functionName: "vamm" }),
      c.readContract({ ...m, functionName: "settlementPrice" }),
      c.readContract({ ...m, functionName: "collateralScale" }),
      c.readContract({ ...m, functionName: "paused" }),
      c.readContract({ address: d.VolIndex, abi: VolIndexAbi, functionName: "latestIndex" }),
      c.readContract({ address: d.VolIndex, abi: VolIndexAbi, functionName: "isReady" }),
    ]);
  return { status: Number(status), expiry, mark, ema, cumFunding, longSize, shortSize, params, vamm, settlementPrice, scale, paused, index: latest[0], ready };
}

function TradeInner({ d, market, index }: { d: Deployment; market: Address; index: number }) {
  const now = useNow(1000);
  const q = useChainQuery(["market", market], (c) => fetchMarketFull(c, d, market));
  const { send, busy } = useTx();
  const client = usePublicClient({ chainId: CHAIN.id }) as PublicClient | undefined;

  if (q.error) return <ErrorBox error={q.error} />;
  if (!q.data) return <Loading />;
  const m = q.data;
  const p = m.params;
  const expired = Number(m.expiry) <= now;

  // Estimated current funding: clamp(ema - index, ±maxPremium·index) / index, per fundingPeriod -> per day.
  let dailyRate = NaN;
  if (m.ema !== undefined && m.index > 0n && m.status === 1) {
    const cap = (m.index * p.maxFundingPremiumBps) / BPS;
    let prem = m.ema - m.index;
    if (prem > cap) prem = cap;
    if (prem < -cap) prem = -cap;
    dailyRate = (toNum(prem) / toNum(m.index)) * (86400 / Number(p.fundingPeriod));
  }
  const maxLev = p.initialMarginBps > 0n ? Number(BPS) / Number(p.initialMarginBps) : NaN;

  const openTrading = () => send("Open trading", { address: market, abi: FuturesMarketAbi, functionName: "openTrading", args: [] });
  const settle = async () => {
    if (!client) return;
    const hint = await lastRoundAtOrBefore(client, d.VolIndex, m.expiry);
    if (hint === null) {
      toast.error("No QVIX round at or before expiry yet");
      return;
    }
    await send("Settle market", { address: market, abi: FuturesMarketAbi, functionName: "settle", args: [hint] });
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <PageTitle
          title={marketLabel(m.expiry)}
          sub={
            <>
              Expiry {fmtDate(m.expiry)} · {expired ? "expired" : `in ${fmtDuration(Number(m.expiry) - now)}`} · market <AddrLink address={market} /> · #{index}
            </>
          }
        />
        <div className="flex items-center gap-2">
          <Badge tone={m.status === 1 ? "up" : m.status === 2 ? "muted" : "accent"}>{MARKET_STATUS[m.status]}</Badge>
          {m.paused && <Badge tone="down">Paused</Badge>}
        </div>
      </div>

      {m.status === 0 && (
        <Notice tone="warn">
          Trading has not opened yet. {m.ready ? "QVIX is ready — anyone can open trading (the vAMM starts at spot QVIX)." : "Waiting for QVIX to fill its 147-return window."}
          {m.ready && (
            <div className="mt-2">
              <WalletGate>
                <Button onClick={openTrading} loading={busy === "Open trading"}>Open trading</Button>
              </WalletGate>
            </div>
          )}
        </Notice>
      )}
      {m.status !== 2 && expired && (
        <Notice tone="warn">
          This market has expired and can be settled by anyone (average of the last {p.settlementRounds.toString()} QVIX prints at or before expiry).
          <div className="mt-2">
            <WalletGate>
              <Button onClick={settle} loading={busy === "Settle market"}>Settle market</Button>
            </WalletGate>
          </div>
        </Notice>
      )}
      {m.status === 2 && (
        <Notice>
          Settled at <b className="text-fg">{fmtQvix(m.settlementPrice)}</b>. Settle your positions on the <Link href="/positions" className="underline">Positions</Link> page.
        </Notice>
      )}

      <Card>
        <div className="grid grid-cols-2 gap-4 md:grid-cols-4 lg:grid-cols-7">
          <Stat label="Spot QVIX" value={m.index > 0n ? fmtQvix(m.index) : "—"} tone="accent" sub={m.ready ? undefined : "warming up"} />
          <Stat label="Futures mark" value={m.status === 1 ? fmtQvix(m.mark) : "—"} />
          <Stat label="EMA mark" value={m.status === 1 ? fmtQvix(m.ema) : "—"} />
          <Stat
            label="Funding (est. / day)"
            value={Number.isFinite(dailyRate) ? fmtPct(dailyRate, 3) : "—"}
            sub={Number.isFinite(dailyRate) ? (dailyRate >= 0 ? "longs pay shorts" : "shorts pay longs") : undefined}
            tone={dailyRate > 0 ? "down" : dailyRate < 0 ? "up" : undefined}
          />
          <Stat label="Cum. funding" value={fmtQvix(m.cumFunding)} sub="QVIX pts / contract" />
          <Stat label="OI long" value={fmtAmount(m.longSize, 18, 2)} sub="contracts" />
          <Stat label="OI short" value={fmtAmount(m.shortSize, 18, 2)} sub="contracts" />
        </div>
      </Card>

      <div className="grid gap-4 lg:grid-cols-3">
        <div className="lg:col-span-2">
          <OrderForm d={d} market={market} m={m} maxLev={maxLev} expired={expired} />
        </div>
        <div className="space-y-4">
          <MarginPanel d={d} />
          <Card title="Market parameters">
            <Row k="Initial margin" v={`${fmtBps(p.initialMarginBps)} (max ${Number.isFinite(maxLev) ? maxLev.toFixed(1) : "—"}x)`} />
            <Row k="Maintenance margin" v={fmtBps(p.maintenanceMarginBps)} />
            <Row k="Trading fee" v={fmtBps(p.tradingFeeBps)} />
            <Row k="Liquidation penalty" v={fmtBps(p.liquidationPenaltyBps)} />
            <Row k="Funding period" v={fmtDuration(Number(p.fundingPeriod))} />
            <Row k="Max funding premium" v={fmtBps(p.maxFundingPremiumBps)} />
            <Row k="Min position notional" v={fmtUsdWad(p.minPositionNotional)} />
            <Row k="Settlement" v={`avg of ${p.settlementRounds} prints`} />
            <Row k="Max settlement price" v={fmtQvix(p.maxSettlementPrice)} />
            <Row k="vAMM" v={<AddrLink address={m.vamm} />} />
          </Card>
        </div>
      </div>
    </div>
  );
}

type MarketFull = Awaited<ReturnType<typeof fetchMarketFull>>;

function OrderForm({ d, market, m, maxLev, expired }: { d: Deployment; market: Address; m: MarketFull; maxLev: number; expired: boolean }) {
  const { address } = useWalletState();
  const [side, setSide] = useState<"long" | "short">("long");
  const [sizeStr, setSizeStr] = useState("");
  const [marginStr, setMarginStr] = useState("");
  const [slipStr, setSlipStr] = useState("1");
  const { send, busy } = useTx();
  const bal = useMarginBalances(d);
  const size = safeParse(sizeStr, 18);
  const isLong = side === "long";
  const tradable = m.status === 1 && !expired && !m.paused;

  const quote = useChainQuery(
    ["quote", m.vamm, side, size?.toString()],
    (c) => c.readContract({ address: m.vamm, abi: VAMMAbi, functionName: "quote", args: [isLong ? size! : -size!] }),
    { enabled: tradable && !!size && size > 0n, refetchInterval: 15_000 },
  );
  const discount = useChainQuery(
    ["discount", d.FeeCollector, address],
    (c) => c.readContract({ address: d.FeeCollector, abi: FeeCollectorAbi, functionName: "feeDiscountBps", args: [address!] }),
    { enabled: !!address && TOKEN_FEATURES && !isZero(d.FeeCollector), refetchInterval: 60_000 },
  );

  const calc = useMemo(() => {
    if (quote.data === undefined || !size || size === 0n) return null;
    const notional = absBig(quote.data); // USD 1e18
    const avg = (notional * WAD) / size;
    const disc = TOKEN_FEATURES ? (discount.data ?? 0n) : 0n;
    const feeWad = (notional * m.params.tradingFeeBps * (BPS - disc)) / (BPS * BPS);
    const ceilDiv = (a: bigint, b: bigint) => (a + b - 1n) / b;
    const fee = ceilDiv(feeWad, m.scale);
    const im = ceilDiv((notional * m.params.initialMarginBps) / BPS, m.scale);
    const minMargin = im + fee;
    const slipBps = BigInt(Math.round(Math.max(0, Number(slipStr) || 0) * 100));
    const priceLimit = slipBps === 0n ? 0n : isLong ? (avg * (BPS + slipBps)) / BPS : (avg * (BPS - slipBps > 0n ? BPS - slipBps : 0n)) / BPS;
    const impact = m.mark && m.mark > 0n ? toNum(avg) / toNum(m.mark) - 1 : NaN;
    return { notional, avg, fee, im, minMargin, priceLimit, disc, impact };
  }, [quote.data, size, discount.data, m, slipStr, isLong]);

  const margin = safeParse(marginStr, USDG.decimals);
  const lev = calc && margin && margin > calc.fee ? toNum(calc.notional) / toNum((margin - calc.fee) * m.scale) : NaN;

  const setLeverage = (x: number) => {
    if (!calc) return;
    const base = (calc.notional * 1000n) / BigInt(Math.round(x * 1000)) / m.scale + 1n;
    const v = base + calc.fee;
    setMarginStr(formatUnits(v, USDG.decimals));
  };

  const errors: string[] = [];
  if (calc && margin !== undefined && margin < calc.minMargin) errors.push(`Margin below the minimum (${fmtUsd(calc.minMargin)} incl. fee).`);
  if (calc && calc.notional < m.params.minPositionNotional) errors.push(`Notional below minimum ${fmtUsdWad(m.params.minPositionNotional)}.`);
  if (margin !== undefined && bal.data && margin > bal.data.free) errors.push("Not enough free margin — deposit USDG into your margin account first.");

  const submit = async () => {
    if (!size || !margin || !calc) return;
    const ok = await send(`Open ${side} ${sizeStr} QVIX`, {
      address: market,
      abi: FuturesMarketAbi,
      functionName: "openPosition",
      args: [isLong, size, margin, calc.priceLimit],
    });
    if (ok) {
      setSizeStr("");
      setMarginStr("");
    }
  };

  return (
    <Card title="Open a position">
      {!tradable && <Notice>{m.status === 1 ? (m.paused ? "Market is paused." : "Market expired — trading closed.") : "Trading is not open for this market."}</Notice>}
      {tradable && (
        <div className="space-y-4">
          <Segmented
            value={side}
            onChange={setSide}
            options={[
              { value: "long", label: "Long — bet on chaos", tone: "up" },
              { value: "short", label: "Short — bet on calm", tone: "down" },
            ]}
          />
          <div className="grid gap-3 sm:grid-cols-2">
            <Input label="Size" value={sizeStr} onChange={(e) => setSizeStr(e.target.value)} placeholder="e.g. 100" suffix="contracts" hint="1 contract = $1 per QVIX point" />
            <Input
              label={`Margin (${USDG.symbol}, incl. fee)`}
              value={marginStr}
              onChange={(e) => setMarginStr(e.target.value)}
              placeholder="0.00"
              suffix={USDG.symbol}
              hint={`Free margin: ${fmtUsd(bal.data?.free)}`}
            />
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-xs text-muted">Leverage:</span>
            {[1, 2, 3, 4, 5].filter((x) => !Number.isFinite(maxLev) || x <= maxLev + 1e-9).map((x) => (
              <button key={x} type="button" disabled={!calc} onClick={() => setLeverage(x)} className="rounded-md border border-line px-2.5 py-1 text-xs hover:border-accent disabled:opacity-40">
                {x}x
              </button>
            ))}
            <span className="ml-auto text-xs text-muted">
              Slippage
              <input
                value={slipStr}
                onChange={(e) => setSlipStr(e.target.value)}
                className="num mx-1 w-12 rounded border border-line bg-panel2 px-1 py-0.5 text-right"
                inputMode="decimal"
              />
              %
            </span>
          </div>

          <div className="rounded-lg bg-panel2 p-3">
            {quote.isFetching && !calc && <div className="text-sm text-muted">Quoting…</div>}
            {quote.error && <div className="text-sm text-down">Quote failed (size may exceed vAMM limits).</div>}
            {!size && <div className="text-sm text-muted">Enter a size to get a quote.</div>}
            {calc && (
              <>
                <Row k="Avg entry price" v={fmtQvix(calc.avg)} />
                <Row k="Price impact vs mark" v={fmtPct(calc.impact, 2)} />
                <Row k="Notional" v={fmtUsdWad(calc.notional)} />
                <Row
                  k={`Trading fee${calc.disc > 0n ? ` (−${fmtBps(calc.disc)} discount)` : ""}`}
                  v={fmtUsd(calc.fee)}
                />
                <Row k="Min margin (initial + fee)" v={fmtUsd(calc.minMargin)} />
                <Row k="Effective leverage" v={Number.isFinite(lev) ? `${lev.toFixed(2)}x` : "—"} />
                <Row k={isLong ? "Max avg price (limit)" : "Min avg price (limit)"} v={calc.priceLimit === 0n ? "disabled" : fmtQvix(calc.priceLimit)} />
              </>
            )}
          </div>
          {errors.map((e) => (
            <Notice key={e} tone="error">{e}</Notice>
          ))}
          <WalletGate message="Connect a wallet to trade.">
            <Button
              variant={isLong ? "up" : "down"}
              className="w-full py-3"
              disabled={!calc || !margin || errors.length > 0}
              loading={!!busy}
              onClick={submit}
            >
              {isLong ? "Open long" : "Open short"}
            </Button>
          </WalletGate>
          <p className="text-xs text-muted">
            Positions can be liquidated if equity falls below the maintenance margin ({fmtBps(m.params.maintenanceMarginBps)} of notional). Funding is paid continuously between longs and shorts. See the{" "}
            <Link href="/risk" className="underline">risk disclosure</Link>.
          </p>
        </div>
      )}
    </Card>
  );
}
