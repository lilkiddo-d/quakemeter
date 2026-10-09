import { getAddress, isAddress, type Address } from "viem";

// NEXT_PUBLIC_* values are inlined at build time; each must be referenced literally.
const rawChainId = process.env.NEXT_PUBLIC_CHAIN_ID;
const rawRpc = process.env.NEXT_PUBLIC_RPC_URL;
const rawWc = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID;
const rawToken = process.env.NEXT_PUBLIC_PROJECT_TOKEN;
const rawGeo = process.env.NEXT_PUBLIC_GEOBLOCK_COUNTRIES;

const parsedChainId = Number((rawChainId ?? "").trim() || "4663");
export const CHAIN_ID: 4663 | 31337 = parsedChainId === 31337 ? 31337 : 4663;
export const RPC_OVERRIDE = (rawRpc ?? "").trim() || undefined;
export const WALLETCONNECT_PROJECT_ID = (rawWc ?? "").trim();

const tokenStr = (rawToken ?? "").trim();
export const PROJECT_TOKEN: Address | undefined = tokenStr && isAddress(tokenStr) ? getAddress(tokenStr) : undefined;
export const TOKEN_FEATURES = PROJECT_TOKEN !== undefined;

export const GEOBLOCK_COUNTRIES: string[] = (rawGeo ?? "")
  .split(",")
  .map((s) => s.trim().toUpperCase())
  .filter((s) => /^[A-Z]{2}$/.test(s));
