/**
 * Off-chain reference implementation of the QVIX methodology (docs/METHODOLOGY.md).
 *
 * Mirrors PriceSampler + VolIndex: equal-weight basket gross return (mean of per-asset price ratios),
 * natural-log return, winsorized at +-maxAbsLogReturn, fixed-size window of returns with the number of
 * sampling periods each return spans, zero-mean annualized variance = periodsPerYear * sum(r^2) / sum(periods),
 * QVIX = 100 * sqrt(variance). Integer steps use BigInt with the same rounding as Solidity; ln/sqrt use
 * float64 (the comparison tolerance accounts for that).
 *
 * Usage as a library: import { computeQvix } from "./qvix.ts"
 * Usage from Foundry FFI:  node scripts/reference/qvix.ts <encoded>  -> prints abi-encoded uint256 (hex)
 *   encoded = "window;periodsPerYear;maxAbsLogReturnWad;quorum;S1|S2|..."  with  S = "periods:p1,p2,..."
 *   prices are 18-decimal integers, 0 = invalid/stale for that sample, periods "max" = gap re-base.
 */

const WAD = 10n ** 18n;

export type Sample = { prices: bigint[]; periods: bigint | "max" };

export type Params = {
  window: number;
  periodsPerYear: bigint;
  maxAbsLogReturn: bigint; // WAD
  quorum: number;
};

export type Result = { qvix: bigint; annualVariance: bigint; returns: number; sumSq: bigint; sumPeriods: bigint };

export function computeQvix(samples: Sample[], p: Params): Result {
  const n = samples.length ? samples[0].prices.length : 0;
  const last: bigint[] = Array(n).fill(0n);
  const ring: { sq: bigint; periods: bigint }[] = [];
  let sumSq = 0n;
  let sumPeriods = 0n;

  for (const s of samples) {
    let ratioSum = 0n;
    let ratioCount = 0;
    let valid = 0;
    for (let i = 0; i < n; i++) {
      const price = s.prices[i];
      if (price === 0n) continue;
      valid++;
      if (last[i] !== 0n) {
        ratioSum += (price * WAD) / last[i];
        ratioCount++;
      }
      last[i] = price;
    }
    if (valid < p.quorum) throw new Error("quorum not met (sample would revert on-chain)");
    if (s.periods === "max") continue;
    if (ratioCount < p.quorum) continue;

    let avg = ratioSum / BigInt(ratioCount);
    if (avg === 0n) avg = 1n;
    let r = BigInt(Math.round(Math.log(Number(avg) / 1e18) * 1e18));
    if (r > p.maxAbsLogReturn) r = p.maxAbsLogReturn;
    if (r < -p.maxAbsLogReturn) r = -p.maxAbsLogReturn;
    const periods = s.periods === 0n ? 1n : s.periods;
    const a = r < 0n ? -r : r;
    const sq = (a * a) / WAD;

    if (ring.length === p.window) {
      const old = ring.shift()!;
      sumSq -= old.sq;
      sumPeriods -= old.periods;
    }
    ring.push({ sq, periods });
    sumSq += sq;
    sumPeriods += periods;
  }

  if (sumPeriods === 0n) return { qvix: 0n, annualVariance: 0n, returns: ring.length, sumSq, sumPeriods };
  const annualVariance = (sumSq * p.periodsPerYear) / sumPeriods;
  const qvix = BigInt(Math.round(Math.sqrt(Number(annualVariance) / 1e18) * 100 * 1e18));
  return { qvix, annualVariance, returns: ring.length, sumSq, sumPeriods };
}

export function decode(encoded: string): { samples: Sample[]; params: Params } {
  const [w, ppy, maxAbs, quorum, body] = encoded.split(";");
  const samples: Sample[] = (body ?? "")
    .split("|")
    .filter((x) => x.length > 0)
    .map((chunk) => {
      const [per, prices] = chunk.split(":");
      return {
        periods: per === "max" ? "max" : BigInt(per),
        prices: prices.split(",").map((v) => BigInt(v)),
      };
    });
  return {
    samples,
    params: { window: Number(w), periodsPerYear: BigInt(ppy), maxAbsLogReturn: BigInt(maxAbs), quorum: Number(quorum) },
  };
}

const isMain = typeof process !== "undefined" && process.argv[1] && /qvix\.ts$/.test(process.argv[1]);
if (isMain) {
  const arg = process.argv[2];
  if (!arg) {
    console.error("usage: node scripts/reference/qvix.ts <encoded>");
    process.exit(1);
  }
  const { samples, params } = decode(arg);
  const { qvix } = computeQvix(samples, params);
  process.stdout.write("0x" + qvix.toString(16).padStart(64, "0"));
}
