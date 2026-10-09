"use client";

import { useMemo, useState } from "react";
import { type PublicClient } from "viem";
import { usePublicClient } from "wagmi";
import { VarianceSwapAbi } from "@/abi";
import { CHAIN, USDG } from "@/config/chain";
import type { Deployment } from "@/config/deployments";
import { ErrorBox, Loading, RequireDeployment, WalletGate } from "@/components/Gates";
import { AddrLink, Badge, Button, Card, Input, Notice, PageTitle, Row, Segmented } from "@/components/ui";
import { WAD, fmtDate, fmtDuration, fmtUsd, safeParse, toNum } from "@/lib/format";
import { useChainQuery, useNow, useWalletState } from "@/lib/hooks";
import { SWAP_STATUS, useIndex } from "@/lib/protocol";
import { firstRoundAtOrAfter, lastRoundAtOrBefore } from "@/lib/rounds";
import { useTx } from "@/lib/tx";

const MAX_LIST = 200n;
const REFUND_GRACE = 30 * 86400;

export function Swaps() {
  return <RequireDeployment>{(d) => <SwapsInner d={d} />}</RequireDeployment>;
}

type SwapRow = {
  id: bigint;
  maker: `0x${string}`;
  taker: `0x${string}`;
  makerIsLong: boolean;
  status: number;
  tenor: bigint;
  offerDeadline: bigint;
  start: bigint;
  end: bigint;
  strikeVar: bigint;
  notional: bigint;
  longCollateral: bigint;
  shortCollateral: bigint;
  realizedVar: bigint;
};

async function fetchSwaps(c: PublicClient, d: Deployment): Promise<SwapRow[]> {
  const next = await c.readContract({ address: d.VarianceSwap, abi: VarianceSwapAbi, functionName: "nextSwapId" });
  const last = next - 1n;
  const first = last > MAX_LIST ? last - MAX_LIST + 1n : 1n;
  const ids: bigint[] = [];
  for (let i = last; i >= first && i >= 1n; i--) ids.push(i);
  const rows = await Promise.all(ids.map((id) => c.readContract({ address: d.VarianceSwap, abi: VarianceSwapAbi, functionName: "getSwap", args: [id] })));
  return rows.map((r, i) => ({
    id: ids[i],
    ...r,
    status: Number(r.status),
    tenor: BigInt(r.tenor),
    offerDeadline: BigInt(r.offerDeadline),
    start: BigInt(r.start),
    end: BigInt(r.end),
  }));
}

/** vol points from variance points² (1e18). */
const volOf = (v: bigint) => Math.sqrt(toNum(v));

function SwapsInner({ d }: { d: Deployment }) {
  const { address } = useWalletState();
  const swaps = useChainQuery(["swaps", d.VarianceSwap], (c) => fetchSwaps(c, d));
  const claimable = useChainQuery(
    ["swapClaimable", d.VarianceSwap, address],
    (c) => c.readContract({ address: d.VarianceSwap, abi: VarianceSwapAbi, functionName: "claimable", args: [address!] }),
    { enabled: !!address },
  );
  const [filter, setFilter] = useState<"open" | "active" | "mine" | "all">("open");
  const { send, busy } = useTx();
  const now = useNow(5000);

  const list = useMemo(() => {
    const rows = swaps.data ?? [];
    const me = address?.toLowerCase();
    switch (filter) {
      case "open":
        return rows.filter((r) => r.status === 1 && Number(r.offerDeadline) >= now);
      case "active":
        return rows.filter((r) => r.status === 2);
      case "mine":
        return rows.filter((r) => me && (r.maker.toLowerCase() === me || r.taker.toLowerCase() === me));
      default:
        return rows;
    }
  }, [swaps.data, filter, address, now]);

  return (
    <div className="space-y-6">
      <PageTitle
        title="Variance swaps"
        sub="Peer-to-peer swaps on realized QVIX variance. Long variance profits if realized vol ends above the strike; short profits if it ends below."
      />
      <div className="grid gap-4 lg:grid-cols-3">
        <div className="space-y-4 lg:col-span-2">
          <Card
            title="Swap board"
            right={
              <div className="w-80 max-w-full">
                <Segmented
                  value={filter}
                  onChange={setFilter}
                  options={[
                    { value: "open", label: "Open" },
                    { value: "active", label: "Active" },
                    { value: "mine", label: "Mine" },
                    { value: "all", label: "All" },
                  ]}
                />
              </div>
            }
          >
            {swaps.error && <ErrorBox error={swaps.error} />}
            {swaps.isLoading && <Loading />}
            {swaps.data && list.length === 0 && <Notice>No swaps in this view.</Notice>}
            <div className="space-y-3">
              {list.map((s) => (
                <SwapCard key={s.id.toString()} s={s} d={d} now={now} />
              ))}
            </div>
          </Card>
        </div>
        <div className="space-y-4">
          <Card title="Claimable">
            <WalletGate message="Connect a wallet to see claimable funds.">
              <Row k={`Claimable ${USDG.symbol}`} v={fmtUsd(claimable.data)} />
              <Button
                className="mt-2 w-full"
                disabled={!claimable.data || claimable.data === 0n}
                loading={busy === "Claim"}
                onClick={() => send("Claim", { address: d.VarianceSwap, abi: VarianceSwapAbi, functionName: "claim", args: [] })}
              >
                Claim
              </Button>
            </WalletGate>
          </Card>
          <CreateOffer d={d} />
        </div>
      </div>
    </div>
  );
}

function SwapCard({ s, d, now }: { s: SwapRow; d: Deployment; now: number }) {
  const { address } = useWalletState();
  const { send, busy, ensureAllowance } = useTx();
  const client = usePublicClient({ chainId: CHAIN.id }) as PublicClient | undefined;
  const me = address?.toLowerCase();
  const isMaker = !!me && s.maker.toLowerCase() === me;
  const takerSide = s.makerIsLong ? "short" : "long";
  const takerDeposit = s.makerIsLong ? s.shortCollateral : s.longCollateral;
  const label = `#${s.id}`;
  const vs = { address: d.VarianceSwap, abi: VarianceSwapAbi } as const;

  const take = async () => {
    if (!(await ensureAllowance(USDG.address, d.VarianceSwap, takerDeposit, USDG.symbol))) return;
    await send(`Take swap ${label}`, { ...vs, functionName: "takeOffer", args: [s.id] });
  };
  const settle = async () => {
    if (!client) return;
    const endHint = await lastRoundAtOrBefore(client, d.VolIndex, s.end);
    const startHint = await firstRoundAtOrAfter(client, d.VolIndex, s.start);
    if (endHint === null) return;
    await send(`Settle swap ${label}`, { ...vs, functionName: "settle", args: [s.id, startHint, endHint] });
  };

  const matured = s.status === 2 && Number(s.end) < now;
  const refundable = s.status === 2 && Number(s.end) + REFUND_GRACE < now;

  return (
    <div className="rounded-lg border border-line bg-panel2 p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <span className="font-semibold">Swap {label}</span>
          <Badge tone={s.makerIsLong ? "up" : "down"}>maker {s.makerIsLong ? "long" : "short"} var</Badge>
          <Badge tone={s.status === 1 ? "accent" : s.status === 2 ? "up" : "muted"}>{SWAP_STATUS[s.status] ?? "?"}</Badge>
          {isMaker && <Badge>yours</Badge>}
        </div>
        <span className="num text-lg font-bold">{volOf(s.strikeVar).toFixed(2)} vol strike</span>
      </div>
      <div className="mt-2 grid grid-cols-2 gap-x-6 sm:grid-cols-3">
        <Row k="Notional / var pt" v={fmtUsd(s.notional)} />
        <Row k="Tenor" v={fmtDuration(Number(s.tenor))} />
        <Row k="Long collateral" v={fmtUsd(s.longCollateral)} />
        <Row k="Short collateral" v={fmtUsd(s.shortCollateral)} />
        <Row k="Maker" v={<AddrLink address={s.maker} />} />
        {s.status === 1 && <Row k="Offer deadline" v={fmtDate(s.offerDeadline)} />}
        {s.status >= 2 && s.taker !== "0x0000000000000000000000000000000000000000" && <Row k="Taker" v={<AddrLink address={s.taker} />} />}
        {s.status >= 2 && s.start > 0n && <Row k="Start" v={fmtDate(s.start)} />}
        {s.status >= 2 && s.end > 0n && <Row k="End" v={fmtDate(s.end)} />}
        {s.status === 3 && <Row k="Realized vol" v={volOf(s.realizedVar).toFixed(2)} />}
      </div>
      <div className="mt-3 flex flex-wrap gap-2">
        {s.status === 1 && !isMaker && Number(s.offerDeadline) >= now && (
          <WalletGate>
            <Button onClick={take} loading={!!busy}>
              Take ({takerSide} var, deposit {fmtUsd(takerDeposit)})
            </Button>
          </WalletGate>
        )}
        {s.status === 1 && isMaker && (
          <Button variant="ghost" loading={busy === `Cancel swap ${label}`} onClick={() => send(`Cancel swap ${label}`, { ...vs, functionName: "cancelOffer", args: [s.id] })}>
            Cancel offer
          </Button>
        )}
        {matured && (
          <WalletGate>
            <Button onClick={settle} loading={busy === `Settle swap ${label}`}>Settle</Button>
          </WalletGate>
        )}
        {refundable && (
          <Button variant="ghost" loading={busy === `Refund swap ${label}`} onClick={() => send(`Refund swap ${label}`, { ...vs, functionName: "refund", args: [s.id] })}>
            Refund (settlement unavailable)
          </Button>
        )}
        {s.status === 2 && !matured && <span className="text-xs text-muted">Matures in {fmtDuration(Number(s.end) - now)}</span>}
      </div>
    </div>
  );
}

function CreateOffer({ d }: { d: Deployment }) {
  const [side, setSide] = useState<"long" | "short">("long");
  const [volStr, setVolStr] = useState("");
  const [notionalStr, setNotionalStr] = useState("");
  const [tenorStr, setTenorStr] = useState("30");
  const [deadlineStr, setDeadlineStr] = useState("7");
  const { send, ensureAllowance, busy } = useTx();
  const idx = useIndex(d);

  const strikeVol = safeParse(volStr, 18);
  const notional = safeParse(notionalStr, USDG.decimals);
  const tenorDays = Number(tenorStr);
  const deadlineDays = Number(deadlineStr);
  const strikeVar = strikeVol ? (strikeVol * strikeVol) / WAD : undefined;
  const validVol = !!strikeVol && strikeVol >= WAD && strikeVol <= 500n * WAD;
  const validTenor = Number.isFinite(tenorDays) && tenorDays >= 1 && tenorDays <= 180;
  const validDeadline = Number.isFinite(deadlineDays) && deadlineDays > 0 && deadlineDays <= 365;

  const coll = useChainQuery(
    ["collateralFor", d.VarianceSwap, strikeVar?.toString(), notional?.toString()],
    (c) => c.readContract({ address: d.VarianceSwap, abi: VarianceSwapAbi, functionName: "collateralFor", args: [strikeVar!, notional!] }),
    { enabled: validVol && !!notional && notional > 0n, refetchInterval: false },
  );
  const deposit = coll.data ? (side === "long" ? coll.data[0] : coll.data[1]) : undefined;

  const submit = async () => {
    if (!strikeVol || !notional || deposit === undefined) return;
    if (!(await ensureAllowance(USDG.address, d.VarianceSwap, deposit, USDG.symbol))) return;
    const tenor = BigInt(Math.round(tenorDays * 86400));
    const deadline = BigInt(Math.floor(Date.now() / 1000) + Math.round(deadlineDays * 86400));
    const ok = await send(`Create ${side} variance offer`, {
      address: d.VarianceSwap,
      abi: VarianceSwapAbi,
      functionName: "createOffer",
      args: [side === "long", strikeVol, notional, tenor, deadline],
    });
    if (ok) {
      setVolStr("");
      setNotionalStr("");
    }
  };

  return (
    <Card title="Create offer">
      <div className="space-y-3">
        <Segmented
          value={side}
          onChange={setSide}
          options={[
            { value: "long", label: "Long var", tone: "up" },
            { value: "short", label: "Short var", tone: "down" },
          ]}
        />
        <Input
          label="Strike volatility (vol points)"
          value={volStr}
          onChange={(e) => setVolStr(e.target.value)}
          placeholder={idx.data?.qvix ? `spot QVIX ${toNum(idx.data.qvix).toFixed(2)}` : "e.g. 20"}
          hint="Between 1 and 500"
        />
        <Input
          label={`Notional (${USDG.symbol} per variance point)`}
          value={notionalStr}
          onChange={(e) => setNotionalStr(e.target.value)}
          placeholder="e.g. 1"
          suffix={USDG.symbol}
          hint="Payoff = notional × (realized vol² − strike vol²), capped at 2.5× strike vol"
        />
        <div className="grid grid-cols-2 gap-2">
          <Input label="Tenor (days)" value={tenorStr} onChange={(e) => setTenorStr(e.target.value)} hint="1–180" />
          <Input label="Offer valid for (days)" value={deadlineStr} onChange={(e) => setDeadlineStr(e.target.value)} />
        </div>
        {coll.data && (
          <div className="rounded-lg bg-panel2 p-3">
            <Row k="Long collateral" v={fmtUsd(coll.data[0])} />
            <Row k="Short collateral" v={fmtUsd(coll.data[1])} />
            <Row k="You deposit" v={<b>{fmtUsd(deposit)}</b>} />
          </div>
        )}
        {volStr && !validVol && <Notice tone="error">Strike vol must be between 1 and 500.</Notice>}
        {!validTenor && <Notice tone="error">Tenor must be 1–180 days.</Notice>}
        <WalletGate message="Connect a wallet to create an offer.">
          <Button className="w-full" disabled={!validVol || !validTenor || !validDeadline || deposit === undefined} loading={!!busy} onClick={submit}>
            Approve &amp; create offer
          </Button>
        </WalletGate>
      </div>
    </Card>
  );
}
