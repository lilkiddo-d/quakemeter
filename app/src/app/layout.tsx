import type { Metadata, Viewport } from "next";
import "@rainbow-me/rainbowkit/styles.css";
import "./globals.css";
import { Providers } from "@/components/Providers";
import { Header } from "@/components/Header";
import { Footer } from "@/components/Footer";
import { RiskModal } from "@/components/RiskModal";

export const metadata: Metadata = {
  title: { default: "Quakemeter — QVIX volatility index", template: "%s · Quakemeter" },
  description: "QVIX: an on-chain realized-volatility index of tokenized stocks, with volatility futures and variance swaps.",
};

export const viewport: Viewport = { themeColor: "#0b0d12", width: "device-width", initialScale: 1 };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className="min-h-screen">
        <Providers>
          <Header />
          <main className="mx-auto max-w-7xl px-4 py-6 sm:py-8">{children}</main>
          <Footer />
          <RiskModal />
        </Providers>
      </body>
    </html>
  );
}
