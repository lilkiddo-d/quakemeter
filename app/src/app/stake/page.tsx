import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { TOKEN_FEATURES } from "@/config/env";
import { Stake } from "@/views/Stake";

export const metadata: Metadata = { title: "Stake" };

export default function Page() {
  // Hidden entirely unless NEXT_PUBLIC_PROJECT_TOKEN is set at build time.
  if (!TOKEN_FEATURES) notFound();
  return <Stake />;
}
