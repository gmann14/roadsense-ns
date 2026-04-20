"use client";

import type { MapMode } from "@/lib/url-state";

const labels: Record<MapMode, string> = {
  quality: "Quality",
  potholes: "Potholes",
  coverage: "Coverage",
};

type ModeSwitcherProps = {
  activeMode: MapMode;
  onSelect: (mode: MapMode) => void;
};

export function ModeSwitcher({ activeMode, onSelect }: ModeSwitcherProps) {
  return (
    <div className="mode-switcher" role="tablist" aria-label="Map mode">
      {(["quality", "potholes", "coverage"] as MapMode[]).map((mode) => (
        <button
          type="button"
          key={mode}
          className={`mode-switcher-button${activeMode === mode ? " active" : ""}`}
          aria-pressed={activeMode === mode}
          onClick={() => onSelect(mode)}
        >
          <span className={`mode-dot ${mode}`} />
          {labels[mode]}
        </button>
      ))}
    </div>
  );
}
