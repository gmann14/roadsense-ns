"use client";

import { usePathname } from "next/navigation";
import { useState } from "react";

import { getMunicipalityByName, municipalityManifest } from "@/lib/municipality-manifest";
import { withUpdatedRouteState, type MapMode } from "@/lib/url-state";

type MunicipalitySearchProps = {
  activeMode: MapMode;
  currentQuery: string | null;
};

export function MunicipalitySearch({ activeMode, currentQuery }: MunicipalitySearchProps) {
  const pathname = usePathname();
  const [value, setValue] = useState(currentQuery ?? "");

  const navigateToSelection = () => {
    const municipality = getMunicipalityByName(value.trim());

    if (municipality) {
      const params = withUpdatedRouteState(new URLSearchParams(), {
        mode: activeMode,
        q: municipality.name,
      });
      window.location.assign(`/municipality/${municipality.slug}?${params.toString()}`);
      return;
    }

    if (value.trim().length === 0 && pathname !== "/") {
      const params = withUpdatedRouteState(new URLSearchParams(), {
        mode: activeMode,
      });
      window.location.assign(`/?${params.toString()}`);
    }
  };

  return (
    <form
      className="municipality-search"
      onSubmit={(event) => {
        event.preventDefault();
        navigateToSelection();
      }}
    >
      <label style={{ display: "grid", gap: 6 }}>
        <span className="eyebrow">Jump to municipality</span>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <input
            className="search-input"
            list="municipality-options"
            placeholder="Halifax, Truro, Kentville…"
            value={value}
            onChange={(event) => setValue(event.target.value)}
          />
          <button type="submit" className="secondary-button">
            Go
          </button>
        </div>
      </label>
      <datalist id="municipality-options">
        {municipalityManifest.map((municipality) => (
          <option key={municipality.slug} value={municipality.name} />
        ))}
      </datalist>
    </form>
  );
}
