"use client";

import { useEffect, useRef } from "react";
import { AreaSeries, ColorType, createChart, type IChartApi, type ISeriesApi, type UTCTimestamp } from "lightweight-charts";

export type Point = { time: number; value: number };

export function QvixChart({ data, height = 300 }: { data: Point[]; height?: number }) {
  const el = useRef<HTMLDivElement>(null);
  const chart = useRef<IChartApi | null>(null);
  const series = useRef<ISeriesApi<"Area"> | null>(null);

  useEffect(() => {
    if (!el.current) return;
    const c = createChart(el.current, {
      height,
      autoSize: true,
      layout: { background: { type: ColorType.Solid, color: "transparent" }, textColor: "#8b93a7", attributionLogo: false },
      grid: { vertLines: { color: "#1c2130" }, horzLines: { color: "#1c2130" } },
      rightPriceScale: { borderColor: "#252a37" },
      timeScale: { borderColor: "#252a37", timeVisible: true, secondsVisible: false },
      crosshair: { mode: 1 },
    });
    series.current = c.addSeries(AreaSeries, {
      lineColor: "#f59e0b",
      topColor: "rgba(245,158,11,0.35)",
      bottomColor: "rgba(245,158,11,0.02)",
      lineWidth: 2,
      priceFormat: { type: "price", precision: 2, minMove: 0.01 },
    });
    chart.current = c;
    return () => {
      c.remove();
      chart.current = null;
      series.current = null;
    };
  }, [height]);

  useEffect(() => {
    if (!series.current) return;
    // lightweight-charts requires strictly increasing times
    const dedup: Point[] = [];
    for (const p of [...data].sort((a, b) => a.time - b.time)) {
      if (dedup.length && dedup[dedup.length - 1].time === p.time) dedup[dedup.length - 1] = p;
      else dedup.push(p);
    }
    series.current.setData(dedup.map((p) => ({ time: p.time as UTCTimestamp, value: p.value })));
    chart.current?.timeScale().fitContent();
  }, [data]);

  return <div ref={el} style={{ height }} className="w-full" />;
}
