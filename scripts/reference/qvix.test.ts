import { test } from "node:test";
import assert from "node:assert/strict";
import { computeQvix, decode } from "./qvix.ts";

const WAD = 10n ** 18n;
const params = { window: 3, periodsPerYear: 1764n, maxAbsLogReturn: WAD / 4n, quorum: 1 };

test("first sample only initializes", () => {
  const r = computeQvix([{ prices: [100n * WAD], periods: "max" }], params);
  assert.equal(r.qvix, 0n);
  assert.equal(r.returns, 0);
});

test("constant 1% hourly moves give 42 vol points", () => {
  // |ln(1.01)| ~ 0.00995 per period, annualized over 1764 periods: 0.00995 * 42 * 100 ~ 41.8
  const s = [{ prices: [100n * WAD], periods: "max" as const }];
  let p = 100n * WAD;
  for (let i = 0; i < 5; i++) {
    p = (p * 101n) / 100n;
    s.push({ prices: [p], periods: 1n } as never);
  }
  const r = computeQvix(s, params);
  assert.equal(r.returns, 3); // window keeps 3
  assert.ok(Math.abs(Number(r.qvix) / 1e18 - 41.79) < 0.05, `got ${Number(r.qvix) / 1e18}`);
});

test("clamping and multi-period returns", () => {
  const s = decode("3;1764;250000000000000000;1;max:100000000000000000000|2:200000000000000000000");
  const r = computeQvix(s.samples, s.params);
  // ln(2) clamped to 0.25 over 2 periods: sqrt(1764 * 0.0625 / 2) * 100
  assert.ok(Math.abs(Number(r.qvix) / 1e18 - Math.sqrt((1764 * 0.0625) / 2) * 100) < 1e-6);
});

test("quorum failure throws like the on-chain revert", () => {
  assert.throws(() => computeQvix([{ prices: [0n, 0n], periods: "max" }], { ...params, quorum: 1 }));
});
