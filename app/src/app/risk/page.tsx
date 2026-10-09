import type { Metadata } from "next";

export const metadata: Metadata = { title: "Risk disclosure" };

export default function Page() {
  return (
    <article className="prose-q mx-auto max-w-3xl">
      <h1 className="text-3xl font-bold">Risk disclosure</h1>
      <p>
        Please read this carefully. Using Quakemeter involves substantial risk, and you may lose some or all of the funds you deposit. Only use money you can
        afford to lose.
      </p>

      <h2>1. Volatility products are complex</h2>
      <p>
        QVIX futures and variance swaps pay out based on the <em>volatility</em> of a basket of tokenized stocks, not their price. Volatility can spike suddenly
        and collapse quickly; it behaves very differently from the underlying stocks. Variance swaps pay on volatility squared, which amplifies outcomes.
      </p>

      <h2>2. Leverage and liquidation</h2>
      <ul>
        <li>Futures can be traded with leverage of up to 5x (20% initial margin). Small moves in QVIX can cause large gains or losses relative to your margin.</li>
        <li>
          If your equity falls below the maintenance margin, your position can be liquidated by anyone, at any time, without notice. A liquidation penalty is
          charged and you may lose your entire margin.
        </li>
        <li>Funding payments accrue continuously and can reduce your equity even if QVIX does not move.</li>
        <li>vAMM pricing has price impact; large orders execute at worse average prices. Slippage limits are optional and protect only the entry/exit price.</li>
      </ul>

      <h2>3. LP / counterparty risk</h2>
      <ul>
        <li>The LP vault is the counterparty to all futures traders. When traders profit, LPs lose. LP share value can fall significantly.</li>
        <li>Deposits are subject to a lock period, and withdrawals are limited by free liquidity reserved against open interest.</li>
        <li>
          If losses exceed a trader’s margin (bad debt), the insurance fund covers it first and the vault after that. Trader profits are paid from the vault;
          in extreme scenarios payouts may be delayed or limited.
        </li>
        <li>Variance swaps are peer-to-peer and fully collateralized up to their cap; returns above the cap are not paid.</li>
      </ul>

      <h2>4. Oracle and index risk</h2>
      <ul>
        <li>
          QVIX is computed from Chainlink price feeds for tokenized stocks. Feeds update when the price moves more than their <strong>deviation threshold
          (0.5%)</strong> or when the <strong>heartbeat</strong> elapses, whichever comes first. Prices can therefore be stale by up to the heartbeat interval and
          miss moves smaller than 0.5%, which biases measured volatility.
        </li>
        <li>Samples are taken at most once per hour during US market hours and must be triggered by someone. Missed or delayed samples change the index.</li>
        <li>
          Single-sample returns are clamped to ±25%, and samples without a quorum of valid prices are skipped. Feed outages, incorrect prices, market halts,
          corporate actions, holidays or calendar errors can distort QVIX and settlement prices.
        </li>
        <li>
          Settlement uses the average of the last QVIX prints at or before expiry. If no valid settlement is possible, governance may settle a market through a
          time-locked emergency procedure.
        </li>
      </ul>

      <h2>5. Smart-contract and operational risk</h2>
      <ul>
        <li>The protocol is experimental software. Contracts may contain bugs or vulnerabilities that lead to a loss of funds, despite testing and review.</li>
        <li>Governance (behind a timelock) and a guardian can pause contracts and change parameters, which may affect open positions.</li>
        <li>
          The underlying network, its sequencer, RPC providers, wallets and this website can fail, be congested or be unavailable, preventing you from managing
          positions in time.
        </li>
        <li>Transactions on public blockchains are irreversible. Double-check every transaction before signing.</li>
      </ul>

      <h2>6. Tokenized stocks and stablecoin</h2>
      <ul>
        <li>
          The tokenized stocks referenced by QVIX are <strong>debt securities issued by a third party</strong>, not the shares themselves. Their prices,
          availability and terms depend on that issuer. Quakemeter does not issue, hold or redeem them and gives no rights to the underlying shares.
        </li>
        <li>Margin and collateral are held in USDG, a third-party stablecoin that may lose its peg, be frozen or become unavailable.</li>
      </ul>

      <h2>7. Regulatory restrictions</h2>
      <p>
        Derivatives on volatility and leveraged products are regulated or prohibited in many jurisdictions. Access may be restricted by geography or by an
        on-chain compliance allowlist, and rules may change at any time, which could force positions to close or make the service unavailable. You are
        responsible for complying with the laws that apply to you.
      </p>

      <h2>8. No investment advice</h2>
      <p>
        Nothing on this website is investment, financial, legal or tax advice, or a recommendation to buy or sell anything. Educational examples are
        simplified and hypothetical. Past index values do not predict future values.
      </p>

      <h2>9. Independence</h2>
      <p>Quakemeter is independent and not affiliated with or endorsed by Robinhood.</p>
    </article>
  );
}
