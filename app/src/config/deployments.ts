import { getAddress, isAddress, type Address } from "viem";
import { RAW_DEPLOYMENTS } from "./deployments.generated";
import { CHAIN_ID } from "./env";

export type Deployment = {
  chainId: number;
  deployedAtBlock?: number;
  deployedAt?: number | string;
  Timelock: Address;
  MarketClock: Address;
  OracleAdapter: Address;
  PriceSampler: Address;
  VolIndex: Address;
  MarginAccount: Address;
  LPVault: Address;
  InsuranceFund: Address;
  FeeCollector: Address;
  ProjectTokenHooks: Address;
  ComplianceRegistry: Address;
  Liquidator: Address;
  VarianceSwap: Address;
  Collateral: Address;
  FuturesMarkets: Address[];
  VAMMs: Address[];
  expiries: number[];
};

const KEYS = [
  "Timelock", "MarketClock", "OracleAdapter", "PriceSampler", "VolIndex", "MarginAccount", "LPVault",
  "InsuranceFund", "FeeCollector", "ProjectTokenHooks", "ComplianceRegistry", "Liquidator", "VarianceSwap",
  "Collateral",
] as const;

function addr(v: unknown): Address | null {
  return typeof v === "string" && isAddress(v) ? getAddress(v) : null;
}

function parse(raw: unknown): Deployment | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  const out: Record<string, unknown> = {};
  for (const k of KEYS) {
    const a = addr(r[k]);
    // Core contracts are required; Compliance/ProjectTokenHooks/etc. fall back to zero address if absent.
    if (!a && (k === "VolIndex" || k === "PriceSampler" || k === "MarginAccount")) return null;
    out[k] = a ?? "0x0000000000000000000000000000000000000000";
  }
  const markets = Array.isArray(r.FuturesMarkets) ? r.FuturesMarkets.map(addr).filter((x): x is Address => !!x) : [];
  const vamms = Array.isArray(r.VAMMs) ? r.VAMMs.map(addr).filter((x): x is Address => !!x) : [];
  const expiries = Array.isArray(r.expiries) ? r.expiries.map((x) => Number(x)).filter((x) => Number.isFinite(x)) : [];
  return {
    ...(out as Omit<Deployment, "chainId" | "FuturesMarkets" | "VAMMs" | "expiries">),
    chainId: Number(r.chainId ?? CHAIN_ID),
    deployedAtBlock: r.deployedAtBlock !== undefined ? Number(r.deployedAtBlock) : undefined,
    deployedAt: r.deployedAt as number | string | undefined,
    FuturesMarkets: markets,
    VAMMs: vamms,
    expiries,
  };
}

/** Deployment for the configured chain, or null when contracts are not deployed there yet. */
export const DEPLOYMENT: Deployment | null = parse(RAW_DEPLOYMENTS[String(CHAIN_ID)]);

export const ZERO: Address = "0x0000000000000000000000000000000000000000";
export const isZero = (a?: string) => !a || /^0x0{40}$/i.test(a);
