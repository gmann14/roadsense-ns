"use client";

import { useState } from "react";

import type { MapMode } from "@/lib/url-state";

type MapLegendProps = {
  defaultExpanded?: boolean;
  mode?: MapMode;
};

type LegendItem = {
  swatchClass: string;
  label: string;
  description: string;
  shape?: "bar" | "dot";
};

const qualityItems: LegendItem[] = [
  { swatchClass: "smooth", label: "Smooth", description: "Recent drives suggest a comparatively steady surface." },
  { swatchClass: "fair", label: "Fair", description: "Noticeable roughness, but not among the harshest mapped roads." },
  { swatchClass: "rough", label: "Rough", description: "Consistently rough enough to stand out in the public signal." },
  { swatchClass: "very-rough", label: "Very rough", description: "Among the harshest mapped roads." },
];

const potholeItems: LegendItem[] = [
  { swatchClass: "very-rough", label: "Confirmed pothole", description: "An impact independently confirmed by multiple drivers.", shape: "dot" },
  { swatchClass: "deep", label: "Top reported pothole", description: "Highlighted from the most-confirmed list.", shape: "dot" },
];

const coverageItems: LegendItem[] = [
  { swatchClass: "coverage-strong", label: "High confidence", description: "Many drivers, many trips. Stable enough to cite." },
  { swatchClass: "coverage-published", label: "Medium", description: "Pattern is real but the pill might shift as more data lands." },
  { swatchClass: "coverage-emerging", label: "Emerging", description: "A hint, not a claim. Treat the colour as provisional." },
];

const titles: Record<MapMode, string> = {
  quality: "Roughness ramp",
  potholes: "Pothole impacts",
  coverage: "Coverage confidence",
};

export function MapLegend({ defaultExpanded = false, mode = "quality" }: MapLegendProps) {
  const [expanded, setExpanded] = useState(defaultExpanded);

  const items = mode === "potholes" ? potholeItems : mode === "coverage" ? coverageItems : qualityItems;

  return (
    <section
      className="map-legend-chip"
      data-expanded={expanded}
      aria-label={`${titles[mode]} legend`}
    >
      <button
        type="button"
        className="map-legend-chip__header"
        aria-expanded={expanded}
        onClick={() => setExpanded((prev) => !prev)}
      >
        <div style={{ display: "grid", gap: 2, textAlign: "left" }}>
          <span className="eyebrow">Legend</span>
          <strong style={{ fontSize: "0.95rem" }}>{titles[mode]}</strong>
        </div>
        <span className="map-legend-chip__swatches" aria-hidden="true">
          {items.map((item) => (
            <span
              key={item.swatchClass}
              className={`legend-swatch ${item.swatchClass}`}
              style={{
                width: item.shape === "dot" ? 8 : 14,
                height: item.shape === "dot" ? 8 : 6,
                borderRadius: item.shape === "dot" ? "50%" : 3,
              }}
            />
          ))}
        </span>
      </button>

      <ul className="legend-list">
        {items.map((item) => (
          <li key={item.label} className="legend-item">
            <span className={`legend-swatch ${item.swatchClass}`} aria-hidden="true" />
            <div style={{ display: "grid", gap: 4 }}>
              <strong>{item.label}</strong>
              <span className="lede" style={{ margin: 0, fontSize: "0.9rem" }}>
                {item.description}
              </span>
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}
