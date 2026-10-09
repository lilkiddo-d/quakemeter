import type { Metadata } from "next";
import { Vault } from "@/views/Vault";

export const metadata: Metadata = { title: "LP Vault" };

export default function Page() {
  return <Vault />;
}
