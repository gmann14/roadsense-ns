"use client";

import { useState } from "react";

import { MIN_CONTRIBUTORS_HIGH_CONFIDENCE, MIN_CONTRIBUTORS_PUBLIC } from "@/lib/site";
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
  {
    swatchClass: "unpaved",
    label: "Unpaved",
    description: "Gravel or dirt, per OpenStreetMap. Not scored against paved roads.",
  },
  {
    swatchClass: "uncategorized",
    label: "No category yet",
    description: "Published, but without enough clean readings for a roughness category.",
  },
];

const potholeItems: LegendItem[] = [
  { swatchClass: "very-rough", label: "Confirmed pothole", description: "An impact independently confirmed by multiple drivers.", shape: "dot" },
  { swatchClass: "deep", label: "Top reported pothole", description: "Highlighted from the most-confirmed list.", shape: "dot" },
];

const coverageItems: LegendItem[] = [
  {
    swatchClass: "coverage-strong",
    label: "High confidence",
    description: `${MIN_CONTRIBUTORS_HIGH_CONFIDENCE}+ different drivers. Stable enough to cite.`,
  },
  {
    swatchClass: "coverage-published",
    label: "Medium",
    description: `${MIN_CONTRIBUTORS_PUBLIC}–${MIN_CONTRIBUTORS_HIGH_CONFIDENCE - 1} drivers. The pattern is real but may shift as more data lands.`,
  },
  {
    swatchClass: "coverage-emerging",
    label: "Emerging",
    description: `Fewer than ${MIN_CONTRIBUTORS_PUBLIC} drivers so far, so no score is published yet.`,
  },
  { swatchClass: "coverage-none", label: "None", description: "No usable drives on this road yet." },
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
