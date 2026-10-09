import type { Metadata } from "next";
import { Positions } from "@/views/Positions";

export const metadata: Metadata = { title: "Positions" };

export default function Page() {
  return <Positions />;
}
