import { formatUnits, parseUnits } from "viem";

export const WAD = 10n ** 18n;
export const BPS = 10_000n;

export function toNum(v: bigint | undefined, decimals = 18): number {
  if (v === undefined) return NaN;
  return Number(formatUnits(v, decimals));
}

function fmt(n: number, min: number, max: number) {
  if (!Number.isFinite(n)) return "—";
  return n.toLocaleString("en-US", { minimumFractionDigits: min, maximumFractionDigits: max });
}

/** QVIX / vol points with 2 decimals (input 1e18). */
export const fmtQvix = (v?: bigint) => (v === undefined ? "—" : fmt(toNum(v), 2, 2));
/** USD amount from 1e18 value. */
export const fmtUsdWad = (v?: bigint) => (v === undefined ? "—" : "$" + fmt(toNum(v), 2, 2));
/** USD amount from token units (default USDG 6 decimals). */
export const fmtUsd = (v?: bigint, decimals = 6) => (v === undefined ? "—" : "$" + fmt(toNum(v, decimals), 2, 2));
export const fmtSignedUsdWad = (v?: bigint) => {
  if (v === undefined) return "—";
  const n = toNum(v);
  return (n >= 0 ? "+$" : "−$") + fmt(Math.abs(n), 2, 2);
};
export const fmtAmount = (v?: bigint, decimals = 18, max = 4) => (v === undefined ? "—" : fmt(toNum(v, decimals), 0, max));
export const fmtBps = (v?: bigint | number) => (v === undefined ? "—" : fmt(Number(v) / 100, 0, 2) + "%");
export const fmtPct = (n: number, max = 2) => (Number.isFinite(n) ? fmt(n * 100, 0, max) + "%" : "—");

export function fmtDate(ts?: bigint | number) {
  if (ts === undefined || Number(ts) === 0) return "—";
  return new Date(Number(ts) * 1000).toLocaleString("en-US", {
    year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", timeZoneName: "short",
  });
}

export function fmtDuration(seconds: number) {
  if (!Number.isFinite(seconds)) return "—";
  const s = Math.max(0, Math.floor(seconds));
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m ${s % 60}s`;
}

export const shortAddr = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "—");

/** Parse a user-entered decimal string; undefined when invalid/empty. */
export function safeParse(value: string, decimals: number): bigint | undefined {
  const v = value.trim();
  if (!v || !/^\d*\.?\d*$/.test(v) || v === ".") return undefined;
  try {
    return parseUnits(v, decimals);
  } catch {
    return undefined;
  }
}

export const absBig = (x: bigint) => (x < 0n ? -x : x);
export const nowSec = () => Math.floor(Date.now() / 1000);
