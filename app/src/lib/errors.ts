import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from "viem";

const FRIENDLY: Record<string, string> = {
  InsufficientMargin: "Not enough margin for this position (initial-margin requirement or fee).",
  InsufficientBalance: "Insufficient free balance in your margin account.",
  SlippageExceeded: "Price moved beyond your slippage tolerance.",
  OiCapExceeded: "Open-interest cap reached for this market — try a smaller size.",
  BelowMinNotional: "Position is below the minimum notional.",
  NotAllowed: "This address is not allowed by the compliance registry.",
  NotReady: "QVIX is not ready yet (window not full).",
  WrongStatus: "Action not available in the current status.",
  NotExpired: "Market has not expired yet.",
  StaleSettlement: "Latest QVIX print is too old to settle this market.",
  BadHint: "Settlement hint is invalid — refresh and retry.",
  Locked: "Your vault deposit is still in the lock period.",
  EnforcedPause: "The contract is paused by the guardian.",
  PriceImpactTooHigh: "Price impact too high — reduce size.",
  NotLiquidatable: "Position is not liquidatable.",
  StillCoolingDown: "Unstake cooldown has not finished yet.",
  TokenNotSet: "Token not yet activated by governance.",
  OfferExpired: "This offer has expired.",
  NotMatured: "Swap has not matured yet.",
  TooEarly: "Too early for this action.",
  Expired: "Market is too close to expiry.",
  ZeroSize: "Size must be greater than zero.",
  ZeroAmount: "Amount must be greater than zero.",
};

export function errorMessage(err: unknown): string {
  if (err instanceof BaseError) {
    if (err.walk((e) => e instanceof UserRejectedRequestError)) return "Transaction rejected in wallet.";
    const revert = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      const name = revert.data?.errorName;
      if (name) return FRIENDLY[name] ?? `Reverted: ${name}`;
      if (revert.reason) return `Reverted: ${revert.reason}`;
    }
    return err.shortMessage || err.message;
  }
  if (err instanceof Error) return err.message.slice(0, 200);
  return String(err);
}
