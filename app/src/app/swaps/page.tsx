import type { Metadata } from "next";
import { Swaps } from "@/views/Swaps";

export const metadata: Metadata = { title: "Variance swaps" };

export default function Page() {
  return <Swaps />;
}
