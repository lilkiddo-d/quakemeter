import type { Metadata } from "next";
import Link from "next/link";
import { BASKET } from "@/config/chain";

export const metadata: Metadata = { title: "Learn: what is volatility?" };

function Example({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="my-4 rounded-lg border border-line bg-panel p-4">
      <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-accent2">Example · {title}</div>
      <div className="text-sm">{children}</div>
    </div>
  );
}

export default function Page() {
  return (
    <article className="prose-q mx-auto max-w-3xl">
      <h1 className="text-3xl font-bold">What is volatility?</h1>
      <p>
        Volatility measures <strong>how much prices wiggle</strong>, not which direction they go. A stock that moves ±0.1% an hour is calm; one that
        moves ±2% an hour is wild. Traders quote volatility as an <em>annualized percentage</em> — “20 vol” means typical yearly moves of about
        20% (one standard deviation).
      </p>

      <h2>Realized vs implied volatility</h2>
      <ul>
        <li>
          <strong>Realized volatility</strong> is backward-looking: it is computed from prices that actually happened. It is a fact you can measure.
        </li>
        <li>
          <strong>Implied volatility</strong> is forward-looking: it is the market’s <em>guess</em> of future volatility, backed out of option prices (the
          famous VIX is an implied-vol index for the S&amp;P 500).
        </li>
      </ul>
      <p>
        <strong>QVIX is a realized-volatility index.</strong> There is no option market behind it — it is computed entirely on-chain from tokenized stock
        prices. QVIX futures then let the market express a view on where realized volatility will be at expiry, so the futures price behaves a lot like an
        implied-vol forecast.
      </p>

      <h2>How QVIX is computed</h2>
      <ol>
        <li>
          <strong>Hourly samples during US market hours.</strong> Between 09:30 and 16:00 New York time on trading days, anyone can trigger one sample per
          hourly slot — that is <strong>7 samples per trading day</strong>. Weekends and exchange holidays are skipped.
        </li>
        <li>
          <strong>Equal-weight basket.</strong> Each sample reads Chainlink prices for {BASKET.length} tokenized stocks ({BASKET.map((b) => b.symbol).join(", ")}) and
          computes the basket’s log return since the previous sample, every stock weighted equally.
        </li>
        <li>
          <strong>Clamp.</strong> Any single-sample return is clamped to ±25% so one bad print cannot blow up the index.
        </li>
        <li>
          <strong>Rolling window.</strong> The last <strong>147 returns</strong> are kept — 21 trading days × 7, roughly <strong>30 calendar days</strong>.
          Until the window is full the index is “warming up” and futures cannot open.
        </li>
        <li>
          <strong>Zero-mean, annualized.</strong> Returns are squared without subtracting an average (standard for realized vol), and annualized with
          <strong> 1,764 periods per year</strong> (252 trading days × 7). Each return counts the number of hourly periods it spans, so a gap is not
          treated as a single hour.
        </li>
      </ol>
      <p>
        <code>QVIX = 100 × √(1764 × Σr² / Σperiods)</code>
      </p>
      <Example title="computing QVIX">
        Suppose every one of the 147 hourly basket returns is ±0.5% (r = 0.005). Then r² = 0.000025, Σr² = 147 × 0.000025 = 0.003675, and Σperiods = 147.
        <br />
        QVIX = 100 × √(1764 × 0.003675 / 147) = 100 × √0.0441 = <strong>21.00</strong>. If hourly moves doubled to ±1%, QVIX would double to 42.
      </Example>

      <h2>What is a QVIX future?</h2>
      <p>
        A QVIX future is a cash-settled bet on where QVIX will be at expiry. <strong>1 contract = $1 per QVIX point.</strong>
      </p>
      <ul>
        <li>
          <strong>Long = bet on chaos.</strong> You profit if volatility rises above your entry price.
        </li>
        <li>
          <strong>Short = bet on calm.</strong> You profit if volatility falls below your entry price.
        </li>
      </ul>
      <p>
        Prices come from a virtual AMM (vAMM) that starts at spot QVIX when trading opens. You post USDG margin; maximum leverage is 5x (20% initial margin). If
        your equity falls below the maintenance margin, anyone can liquidate your position and a penalty is charged.
      </p>
      <Example title="going long">
        You buy 100 contracts at 20.00. Notional = 100 × $20 = $2,000. At 5x you post about $400 of margin plus a small trading fee. At expiry QVIX settles at
        26.00 → profit = 100 × (26 − 20) = <strong>$600</strong>. If instead QVIX drifts to 17, you are down $300 — at 5x leverage that is most of your margin,
        and you would likely be liquidated before reaching that point.
      </Example>

      <h2>Funding</h2>
      <p>
        Between trades, the futures price can drift away from spot QVIX. <strong>Funding</strong> nudges it back: if the (smoothed, EMA) futures mark is above
        the index, longs pay shorts; if below, shorts pay longs. The premium is capped at ±10% of the index and paid continuously over each funding period
        (one day by default).
      </p>
      <Example title="funding">
        Index = 20, EMA mark = 21 → premium = 1 point (5% of index). Over one day a long holder of 100 contracts pays about 100 × 1 = $100 to shorts, accrued
        second by second. Funding stops at expiry.
      </Example>

      <h2>Settlement</h2>
      <p>
        Futures expire on the <strong>third Friday of the month at 16:00 New York time</strong>. The settlement price is the <strong>average of the last 7
        QVIX prints at or before expiry</strong> (about one trading day), which makes it hard to manipulate a single print. After expiry anyone can call
        “Settle market”; each trader then settles their own position and the payout returns to their margin account.
      </p>

      <h2>Variance swaps</h2>
      <p>
        A variance swap pays the difference between <em>realized variance</em> (vol²) over a period and a fixed <em>strike variance</em> agreed today. They are
        peer-to-peer: one user posts an offer, another takes it, and both lock collateral. Realized variance is measured from the QVIX history between the swap’s
        start and end, and is capped at (2.5 × strike vol)² so the maximum loss of each side is known up front.
      </p>
      <Example title="variance swap">
        Strike = 20 vol → strike variance 400. Notional = $1 per variance point. Over the tenor realized vol is 25 → variance 625.
        <br />
        Long variance receives (625 − 400) × $1 = <strong>$225</strong>. If realized vol were 15 (variance 225), long would pay (400 − 225) × $1 = $175. The
        long side posts $400 (worst case: zero variance) and the short side posts $2,100 (worst case: the 50-vol cap, variance 2,500).
      </Example>
      <p>
        Because payoffs scale with vol <em>squared</em>, variance swaps gain more from big spikes than they lose from calm periods — that convexity is why the
        strike usually sits above the expected volatility.
      </p>

      <h2>Where to go next</h2>
      <p>
        Read the <Link href="/risk">risk disclosure</Link>, watch the index on the <Link href="/">dashboard</Link>, then try a small trade on the{" "}
        <Link href="/trade">trade</Link> page.
      </p>
    </article>
  );
}
