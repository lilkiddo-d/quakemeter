import type { Metadata } from "next";
import { TradeMarket } from "@/views/Trade";

export const metadata: Metadata = { title: "Trade" };

export default async function Page({ params }: { params: Promise<{ market: string }> }) {
  const { market } = await params;
  return <TradeMarket market={decodeURIComponent(market)} />;
}
