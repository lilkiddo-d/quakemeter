import type { Address, PublicClient } from "viem";
import { VolIndexAbi } from "@/abi";

const CAPACITY = 8192n; // VolIndex.HISTORY_CAPACITY

export type Round = { id: bigint; timestamp: bigint; cumPeriods: bigint; qvix: bigint; cumSumSq: bigint };

export async function getRound(client: PublicClient, volIndex: Address, id: bigint): Promise<Round> {
  const r = await client.readContract({ address: volIndex, abi: VolIndexAbi, functionName: "getRound", args: [id] });
  return { id, timestamp: BigInt(r.timestamp), cumPeriods: BigInt(r.cumPeriods), qvix: BigInt(r.qvix), cumSumSq: r.cumSumSq };
}

async function bounds(client: PublicClient, volIndex: Address) {
  const latest = await client.readContract({ address: volIndex, abi: VolIndexAbi, functionName: "latestRoundId" });
  const oldest = latest >= CAPACITY ? latest - CAPACITY + 1n : 1n;
  return { latest, oldest };
}

/** Last round with timestamp <= cutoff (binary search over the monotonic history ring), or null. */
export async function lastRoundAtOrBefore(client: PublicClient, volIndex: Address, cutoff: bigint): Promise<bigint | null> {
  const { latest, oldest } = await bounds(client, volIndex);
  if (latest === 0n) return null;
  if ((await getRound(client, volIndex, oldest)).timestamp > cutoff) return null;
  let lo = oldest;
  let hi = latest;
  while (lo < hi) {
    const mid = (lo + hi + 1n) / 2n;
    if ((await getRound(client, volIndex, mid)).timestamp <= cutoff) lo = mid;
    else hi = mid - 1n;
  }
  return lo;
}

/** First round with timestamp >= t; latestRoundId + 1 when no such round exists yet. */
export async function firstRoundAtOrAfter(client: PublicClient, volIndex: Address, t: bigint): Promise<bigint> {
  const { latest, oldest } = await bounds(client, volIndex);
  if (latest === 0n) return 1n;
  if ((await getRound(client, volIndex, latest)).timestamp < t) return latest + 1n;
  let lo = oldest;
  let hi = latest;
  while (lo < hi) {
    const mid = (lo + hi) / 2n;
    if ((await getRound(client, volIndex, mid)).timestamp >= t) hi = mid;
    else lo = mid + 1n;
  }
  return lo;
}

/** Last up to `n` rounds ending at `latest`, oldest first. */
export async function recentRounds(client: PublicClient, volIndex: Address, latest: bigint, n = 500): Promise<Round[]> {
  if (latest === 0n) return [];
  const oldestAvail = latest >= CAPACITY ? latest - CAPACITY + 1n : 1n;
  let first = latest - BigInt(n) + 1n;
  if (first < oldestAvail) first = oldestAvail;
  const ids: bigint[] = [];
  for (let i = first; i <= latest; i++) ids.push(i);
  const res = await Promise.allSettled(ids.map((id) => getRound(client, volIndex, id)));
  return res.flatMap((r) => (r.status === "fulfilled" ? [r.value] : []));
}
