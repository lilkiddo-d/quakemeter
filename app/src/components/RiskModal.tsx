"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { Button } from "./ui";

const KEY = "quakemeter.riskAccepted.v1";

function read(): boolean {
  try {
    return window.localStorage.getItem(KEY) === "1";
  } catch {
    return false;
  }
}

/** First-visit gate: user must accept the risk disclosure before using the app. */
export function RiskModal() {
  const path = usePathname();
  const [show, setShow] = useState(false);
  const [checked, setChecked] = useState(false);

  useEffect(() => {
    setShow(!read());
  }, []);

  if (!show || path.startsWith("/risk") || path.startsWith("/blocked") || path.startsWith("/learn")) return null;

  const accept = () => {
    try {
      window.localStorage.setItem(KEY, "1");
    } catch {
      /* storage unavailable: accept for this session only */
    }
    setShow(false);
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4">
      <div role="dialog" aria-modal="true" className="max-h-[90vh] w-full max-w-lg overflow-y-auto rounded-xl border border-line bg-panel p-6">
        <h2 className="text-xl font-bold">Before you continue</h2>
        <div className="mt-3 space-y-2 text-sm text-muted">
          <p>Quakemeter lets you trade QVIX volatility futures (up to 5x leverage), variance swaps, and provide liquidity as the counterparty to traders.</p>
          <ul className="list-disc space-y-1 pl-5">
            <li>You can lose all of your margin; leveraged positions can be liquidated quickly.</li>
            <li>LPs take the other side of trader PnL and can lose money.</li>
            <li>QVIX depends on oracle prices of tokenized stocks and on smart contracts that may contain bugs.</li>
            <li>These products may be restricted in your jurisdiction. Nothing here is investment advice.</li>
          </ul>
        </div>
        <label className="mt-4 flex items-start gap-2 text-sm">
          <input type="checkbox" className="mt-1 accent-amber-500" checked={checked} onChange={(e) => setChecked(e.target.checked)} />
          <span>
            I have read and understood the{" "}
            <Link href="/risk" className="text-accent2 underline">risk disclosure</Link>, and I am not accessing Quakemeter from a restricted jurisdiction.
          </span>
        </label>
        <div className="mt-5 flex justify-end gap-2">
          <Link href="/learn" className="rounded-lg border border-line px-4 py-2 text-sm">Learn first</Link>
          <Button disabled={!checked} onClick={accept}>Accept &amp; continue</Button>
        </div>
      </div>
    </div>
  );
}
