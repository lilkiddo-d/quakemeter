import type { Metadata } from "next";
import { TradeIndex } from "@/views/Trade";

export const metadata: Metadata = { title: "Trade" };

export default function Page() {
  return <TradeIndex />;
}
