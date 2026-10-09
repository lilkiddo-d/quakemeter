import Link from "next/link";
import { EXPLORER } from "@/config/chain";
import { DEPLOYMENT } from "@/config/deployments";

const CONTRACTS = [
  "VolIndex",
  "PriceSampler",
  "MarketClock",
  "MarginAccount",
  "LPVault",
  "InsuranceFund",
  "FeeCollector",
  "Liquidator",
  "VarianceSwap",
  "ProjectTokenHooks",
  "ComplianceRegistry",
  "Timelock",
] as const;

export function Footer() {
  return (
    <footer className="mt-16 border-t border-line">
      <div className="mx-auto grid max-w-7xl gap-6 px-4 py-8 text-xs text-muted md:grid-cols-3">
        <div className="space-y-2">
          <div className="text-sm font-semibold text-fg">Quakemeter</div>
          <p>QVIX is an on-chain realized-volatility index of tokenized stocks. Volatility futures and variance swaps are high-risk products.</p>
          <p>Quakemeter is independent and not affiliated with or endorsed by Robinhood.</p>
          <p>Nothing on this site is investment advice.</p>
        </div>
        <div className="space-y-1">
          <div className="text-sm font-semibold text-fg">Links</div>
          <Link href="/risk" className="block hover:text-fg">Risk disclosure</Link>
          <Link href="/learn" className="block hover:text-fg">What is volatility?</Link>
          {EXPLORER && (
            <a href={EXPLORER} target="_blank" rel="noopener noreferrer" className="block hover:text-fg">
              Block explorer
            </a>
          )}
        </div>
        <div className="space-y-1">
          <div className="text-sm font-semibold text-fg">Contracts</div>
          {!DEPLOYMENT && <p>Not deployed on this network yet.</p>}
          {DEPLOYMENT && (
            <div className="grid grid-cols-2 gap-x-4 gap-y-1">
              {CONTRACTS.map((c) => {
                const a = DEPLOYMENT![c];
                if (!a || /^0x0{40}$/i.test(a)) return null;
                return EXPLORER ? (
                  <a key={c} href={`${EXPLORER}/address/${a}`} target="_blank" rel="noopener noreferrer" className="truncate hover:text-fg">
                    {c}
                  </a>
                ) : (
                  <span key={c} className="truncate" title={a}>{c}</span>
                );
              })}
            </div>
          )}
        </div>
      </div>
    </footer>
  );
}
