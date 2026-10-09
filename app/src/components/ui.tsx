"use client";

import type { ButtonHTMLAttributes, InputHTMLAttributes, ReactNode } from "react";
import { explorerAddress } from "@/config/chain";
import { shortAddr } from "@/lib/format";

export function cx(...c: (string | false | null | undefined)[]) {
  return c.filter(Boolean).join(" ");
}

export function Card({ title, right, children, className }: { title?: ReactNode; right?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={cx("rounded-xl border border-line bg-panel p-4 sm:p-5", className)}>
      {(title || right) && (
        <div className="mb-3 flex items-center justify-between gap-2">
          {title && <h2 className="text-sm font-semibold uppercase tracking-wide text-muted">{title}</h2>}
          {right}
        </div>
      )}
      {children}
    </section>
  );
}

export function Stat({ label, value, sub, tone }: { label: ReactNode; value: ReactNode; sub?: ReactNode; tone?: "up" | "down" | "accent" }) {
  return (
    <div className="min-w-0">
      <div className="text-xs text-muted">{label}</div>
      <div
        className={cx(
          "num truncate text-lg font-semibold",
          tone === "up" && "text-up",
          tone === "down" && "text-down",
          tone === "accent" && "text-accent2",
        )}
      >
        {value}
      </div>
      {sub && <div className="text-xs text-muted">{sub}</div>}
    </div>
  );
}

export function Button({
  variant = "primary",
  className,
  loading,
  children,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: "primary" | "ghost" | "danger" | "up" | "down"; loading?: boolean }) {
  return (
    <button
      {...rest}
      disabled={rest.disabled || loading}
      className={cx(
        "inline-flex items-center justify-center gap-2 rounded-lg px-4 py-2 text-sm font-semibold transition disabled:cursor-not-allowed disabled:opacity-40",
        variant === "primary" && "bg-accent text-gray-900 hover:bg-accent2",
        variant === "ghost" && "border border-line bg-panel2 text-fg hover:border-muted",
        variant === "danger" && "bg-down/90 text-white hover:bg-down",
        variant === "up" && "bg-up text-gray-900 hover:brightness-110",
        variant === "down" && "bg-down text-white hover:brightness-110",
        className,
      )}
    >
      {loading && <span className="h-3 w-3 animate-spin rounded-full border-2 border-current border-t-transparent" />}
      {children}
    </button>
  );
}

export function Input({ label, suffix, hint, className, ...rest }: InputHTMLAttributes<HTMLInputElement> & { label?: ReactNode; suffix?: ReactNode; hint?: ReactNode }) {
  return (
    <label className={cx("block", className)}>
      {label && <span className="mb-1 block text-xs text-muted">{label}</span>}
      <span className="flex items-center rounded-lg border border-line bg-panel2 focus-within:border-accent">
        <input
          inputMode="decimal"
          autoComplete="off"
          {...rest}
          className="num w-full min-w-0 bg-transparent px-3 py-2 text-sm outline-none placeholder:text-muted/60"
        />
        {suffix && <span className="shrink-0 pr-3 text-xs text-muted">{suffix}</span>}
      </span>
      {hint && <span className="mt-1 block text-xs text-muted">{hint}</span>}
    </label>
  );
}

export function Badge({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "up" | "down" | "accent" }) {
  return (
    <span
      className={cx(
        "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
        tone === "muted" && "bg-panel2 text-muted",
        tone === "up" && "bg-up/15 text-up",
        tone === "down" && "bg-down/15 text-down",
        tone === "accent" && "bg-accent/15 text-accent2",
      )}
    >
      {children}
    </span>
  );
}

export function Notice({ children, tone = "info" }: { children: ReactNode; tone?: "info" | "warn" | "error" }) {
  return (
    <div
      className={cx(
        "rounded-lg border px-4 py-3 text-sm",
        tone === "info" && "border-line bg-panel2 text-muted",
        tone === "warn" && "border-accent/40 bg-accent/10 text-accent2",
        tone === "error" && "border-down/40 bg-down/10 text-down",
      )}
    >
      {children}
    </div>
  );
}

export function Segmented<T extends string>({ value, options, onChange }: { value: T; options: { value: T; label: ReactNode; tone?: "up" | "down" }[]; onChange: (v: T) => void }) {
  return (
    <div className="grid grid-flow-col auto-cols-fr gap-1 rounded-lg border border-line bg-panel2 p-1">
      {options.map((o) => (
        <button
          key={o.value}
          type="button"
          onClick={() => onChange(o.value)}
          className={cx(
            "rounded-md px-3 py-1.5 text-sm font-semibold transition",
            value === o.value
              ? o.tone === "up"
                ? "bg-up text-gray-900"
                : o.tone === "down"
                  ? "bg-down text-white"
                  : "bg-accent text-gray-900"
              : "text-muted hover:text-fg",
          )}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function AddrLink({ address, label }: { address?: string; label?: ReactNode }) {
  if (!address) return <span>—</span>;
  const href = explorerAddress(address);
  const text = label ?? shortAddr(address);
  return href ? (
    <a href={href} target="_blank" rel="noopener noreferrer" className="font-mono text-accent2 hover:underline">
      {text}
    </a>
  ) : (
    <span className="font-mono">{text}</span>
  );
}

export function Row({ k, v }: { k: ReactNode; v: ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-3 py-1 text-sm">
      <span className="text-muted">{k}</span>
      <span className="num text-right">{v}</span>
    </div>
  );
}

export function PageTitle({ title, sub }: { title: ReactNode; sub?: ReactNode }) {
  return (
    <div className="mb-6">
      <h1 className="text-2xl font-bold sm:text-3xl">{title}</h1>
      {sub && <p className="mt-1 text-sm text-muted">{sub}</p>}
    </div>
  );
}

export function Spinner() {
  return <span className="inline-block h-4 w-4 animate-spin rounded-full border-2 border-muted border-t-transparent" />;
}
