"use client";

import type { Address, PublicClient } from "viem";
import { FuturesMarketAbi, MarketClockAbi, PriceSamplerAbi, VolIndexAbi } from "@/abi";
import type { Deployment } from "@/config/deployments";
import { safe, useChainQuery } from "./hooks";

export const MARKET_STATUS = ["Pending", "Trading", "Settled"] as const;
export const SWAP_STATUS = ["None", "Open", "Active", "Settled", "Cancelled", "Refunded"] as const;

export type IndexState = {
  qvix: bigint;
  ts: bigint;
  ready: boolean;
  returnCount: bigint;
  windowSize: bigint;
  latestRoundId: bigint;
  marketOpen: boolean;
  canSample: boolean;
  lastSampleTs: bigint;
};

export async function fetchIndex(client: PublicClient, d: Deployment): Promise<IndexState> {
  const now = BigInt(Math.floor(Date.now() / 1000));
  const vi = { address: d.VolIndex, abi: VolIndexAbi } as const;
  const ps = { address: d.PriceSampler, abi: PriceSamplerAbi } as const;
  const [latest, ready, returnCount, windowSize, latestRoundId, marketOpen, canSample, lastSampleTs] = await Promise.all([
    client.readContract({ ...vi, functionName: "latestIndex" }),
    client.readContract({ ...vi, functionName: "isReady" }),
    client.readContract({ ...ps, functionName: "returnCount" }),
    client.readContract({ ...ps, functionName: "windowSize" }),
    client.readContract({ ...vi, functionName: "latestRoundId" }),
    safe(client.readContract({ address: d.MarketClock, abi: MarketClockAbi, functionName: "isOpen", args: [now] })),
    safe(client.readContract({ ...vi, functionName: "canSample" })),
    client.readContract({ ...vi, functionName: "lastSampleTs" }),
  ]);
  return {
    qvix: latest[0],
    ts: latest[1],
    ready,
    returnCount,
    windowSize,
    latestRoundId,
    marketOpen: marketOpen ?? false,
    canSample: canSample ?? false,
    lastSampleTs,
  };
}

export function useIndex(d: Deployment | null) {
  return useChainQuery(["index", d?.VolIndex], (c) => fetchIndex(c, d!), { enabled: !!d });
}

export type MarketSummary = {
  address: Address;
  index: number;
  expiry: bigint;
  status: number;
  mark?: bigint;
  ema?: bigint;
  settlementPrice: bigint;
  longSize: bigint;
  shortSize: bigint;
};

export async function fetchMarket(client: PublicClient, address: Address, index: number): Promise<MarketSummary> {
  const m = { address, abi: FuturesMarketAbi } as const;
  const [expiry, status, mark, ema, settlementPrice, longSize, shortSize] = await Promise.all([
    client.readContract({ ...m, functionName: "expiry" }),
    client.readContract({ ...m, functionName: "status" }),
    safe(client.readContract({ ...m, functionName: "markPrice" })),
    safe(client.readContract({ ...m, functionName: "emaMarkPrice" })),
    client.readContract({ ...m, functionName: "settlementPrice" }),
    client.readContract({ ...m, functionName: "longSize" }),
    client.readContract({ ...m, functionName: "shortSize" }),
  ]);
  return { address, index, expiry, status: Number(status), mark, ema, settlementPrice, longSize, shortSize };
}

export function useMarkets(d: Deployment | null) {
  return useChainQuery(
    ["markets", d?.FuturesMarkets.join(",")],
    (c) => Promise.all((d?.FuturesMarkets ?? []).map((a, i) => fetchMarket(c, a, i))),
    { enabled: !!d },
  );
}

export function marketLabel(expiry: bigint | number) {
  const dt = new Date(Number(expiry) * 1000);
  return `QVIX ${dt.toLocaleString("en-US", { month: "short", year: "numeric", timeZone: "America/New_York" })}`;
}

/** Next hourly sample slot (09:30 + k·60min ET, until 16:00) — informational estimate only; MarketClock is authoritative. */
export function nextSlotEstimate(nowSec: number): Date {
  const fmt = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York",
    hour12: false,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    weekday: "short",
  });
  // Walk forward in 1-minute steps (max 4 days) until an ET weekday minute aligns to :30 between 09:30 and 15:30.
  for (let t = nowSec - (nowSec % 60) + 60; t < nowSec + 4 * 86400; t += 60) {
    const parts = Object.fromEntries(fmt.formatToParts(new Date(t * 1000)).map((p) => [p.type, p.value]));
    const wd = parts.weekday;
    if (wd === "Sat" || wd === "Sun") continue;
    const h = Number(parts.hour) % 24;
    const m = Number(parts.minute);
    const mins = h * 60 + m;
    if (m === 30 && mins >= 570 && mins <= 930) return new Date(t * 1000);
  }
  return new Date((nowSec + 3600) * 1000);
}
