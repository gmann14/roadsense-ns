"use client";

import { useState } from "react";

type MapLegendProps = {
  defaultExpanded?: boolean;
};

const items = [
  { className: "smooth", label: "Smooth", description: "Community readings suggest a comparatively steady surface." },
  { className: "fair", label: "Fair", description: "Noticeable roughness, but not among the harshest road sections." },
  { className: "rough", label: "Rough", description: "Consistently rough enough to stand out in the public signal." },
  { className: "very-rough", label: "Very rough", description: "Among the harshest community-published road sections." },
];

export function MapLegend({ defaultExpanded = false }: MapLegendProps) {
  const [expanded, setExpanded] = useState(defaultExpanded);

  return (
    <section
      className="map-legend-chip"
      data-expanded={expanded}
      aria-label="Road quality legend"
    >
      <button
        type="button"
        className="map-legend-chip__header"
        aria-expanded={expanded}
        onClick={() => setExpanded((prev) => !prev)}
      >
        <div style={{ display: "grid", gap: 2, textAlign: "left" }}>
          <span className="eyebrow">Legend</span>
          <strong style={{ fontSize: "0.95rem" }}>Roughness ramp</strong>
        </div>
        <span className="map-legend-chip__swatches" aria-hidden="true">
          {items.map((item) => (
            <span key={item.className} className={`legend-swatch ${item.className}`} style={{ width: 14, height: 6, borderRadius: 3 }} />
          ))}
        </span>
      </button>

      <ul className="legend-list">
        {items.map((item) => (
          <li key={item.label} className="legend-item">
            <span className={`legend-swatch ${item.className}`} aria-hidden="true" />
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
