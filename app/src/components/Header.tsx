"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useSwitchChain } from "wagmi";
import { CHAIN } from "@/config/chain";
import { TOKEN_FEATURES } from "@/config/env";
import { useMounted, useWalletState } from "@/lib/hooks";
import { cx } from "./ui";

const NAV = [
  { href: "/", label: "Dashboard" },
  { href: "/trade", label: "Trade" },
  { href: "/positions", label: "Positions" },
  { href: "/vault", label: "Vault" },
  { href: "/swaps", label: "Var Swaps" },
  ...(TOKEN_FEATURES ? [{ href: "/stake", label: "Stake" }] : []),
  { href: "/learn", label: "Learn" },
];

function Logo() {
  return (
    <svg viewBox="0 0 32 32" className="h-7 w-7" aria-hidden>
      <rect width="32" height="32" rx="8" fill="#f59e0b" />
      <path d="M4 17h5l2-6 3 12 3-16 3 14 2-4h6" fill="none" stroke="#111827" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

export function NetworkBadge() {
  const mounted = useMounted();
  const { wrongNetwork } = useWalletState();
  const { switchChain } = useSwitchChain();
  if (mounted && wrongNetwork) {
    return (
      <button
        onClick={() => switchChain({ chainId: CHAIN.id })}
        className="rounded-full bg-down/20 px-3 py-1 text-xs font-semibold text-down hover:bg-down/30"
      >
        Wrong network — switch
      </button>
    );
  }
  return (
    <span className="hidden items-center gap-1.5 whitespace-nowrap rounded-full border border-line px-3 py-1 text-xs text-muted xl:inline-flex">
      <span className="h-1.5 w-1.5 rounded-full bg-up" />
      {CHAIN.name}
    </span>
  );
}

export function Header() {
  const path = usePathname();
  const [open, setOpen] = useState(false);
  const active = (href: string) => (href === "/" ? path === "/" : path.startsWith(href));
  return (
    <header className="sticky top-0 z-30 border-b border-line bg-bg/90 backdrop-blur">
      <div className="mx-auto flex max-w-7xl items-center gap-4 px-4 py-3">
        <Link href="/" className="flex items-center gap-2 font-bold">
          <Logo />
          <span className="text-lg">Quakemeter</span>
        </Link>
        <nav className="hidden flex-1 items-center gap-1 lg:flex">
          {NAV.map((n) => (
            <Link
              key={n.href}
              href={n.href}
              className={cx(
                "whitespace-nowrap rounded-md px-3 py-1.5 text-sm",
                active(n.href) ? "bg-panel2 text-fg" : "text-muted hover:text-fg",
              )}
            >
              {n.label}
            </Link>
          ))}
        </nav>
        <div className="ml-auto flex items-center gap-2">
          <NetworkBadge />
          <ConnectButton chainStatus="none" showBalance={false} accountStatus={{ smallScreen: "avatar", largeScreen: "address" }} />
          <button
            className="rounded-md border border-line p-2 lg:hidden"
            aria-label="Menu"
            onClick={() => setOpen((o) => !o)}
          >
            <svg viewBox="0 0 20 20" className="h-4 w-4" fill="currentColor">
              <path d="M2 4h16v2H2zM2 9h16v2H2zM2 14h16v2H2z" />
            </svg>
          </button>
        </div>
      </div>
      {open && (
        <nav className="border-t border-line px-4 py-2 lg:hidden">
          {NAV.map((n) => (
            <Link
              key={n.href}
              href={n.href}
              onClick={() => setOpen(false)}
              className={cx("block rounded-md px-3 py-2 text-sm", active(n.href) ? "bg-panel2" : "text-muted")}
            >
              {n.label}
            </Link>
          ))}
        </nav>
      )}
    </header>
  );
}
