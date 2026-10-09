import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = { title: "Not available in your region" };

export default function Page() {
  return (
    <div className="mx-auto max-w-xl py-16 text-center">
      <h1 className="text-2xl font-bold">Not available in your region</h1>
      <p className="mt-3 text-sm text-muted">
        Quakemeter is not available to users located in your country or region. Volatility derivatives may be restricted where you are.
      </p>
      <p className="mt-6 text-sm">
        <Link href="/risk" className="text-accent2 underline">Read the risk disclosure</Link>
      </p>
    </div>
  );
}
