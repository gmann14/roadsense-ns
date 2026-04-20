"use client";

import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useState } from "react";

import type { Bbox, PublicStats } from "@/lib/api/client";
import type { MunicipalityConfig } from "@/lib/municipality-manifest";
import {
  parseViewportState,
  searchParamRecordToUrlSearchParams,
  withUpdatedRouteState,
  type MapMode,
  type SearchParamRecord,
} from "@/lib/url-state";

import { ModeSwitcher } from "./mode-switcher";
import { MunicipalitySearch } from "./municipality-search";
import { MapLegend } from "./map-legend";
import { RoadQualityMapView } from "./road-quality-map-view";
import { SegmentDrawer } from "./segment-drawer";

type MapExplorerProps = {
  municipality?: MunicipalityConfig | null;
  searchParams?: SearchParamRecord;
  stats: PublicStats | null;
};

const modeSummaryCopy: Record<MapMode, string> = {
  quality:
    "Published community road-quality segments render live here. Click a road to open the detail drawer.",
  potholes:
    "Potholes mode isolates active markers so the public can inspect hazard clusters without mixing them into the quality ramp.",
  coverage:
    "Coverage mode answers where RoadSense has enough contributor density to publish reliable road-quality signal.",
};

export function MapExplorer({ municipality, searchParams = {}, stats }: MapExplorerProps) {
  const pathname = usePathname();
  const router = useRouter();
  const liveSearchParams = useSearchParams();
  const [mapReady, setMapReady] = useState(false);
  const [mapError, setMapError] = useState<string | null>(null);
  const [visibleBbox, setVisibleBbox] = useState<Bbox | null>(null);

  const baseSearchParams =
    liveSearchParams.size > 0 ? new URLSearchParams(liveSearchParams) : searchParamRecordToUrlSearchParams(searchParams);
  const routeState = parseViewportState(baseSearchParams);

  const navigate = (nextParams: URLSearchParams, action: "push" | "replace") => {
    const nextUrl = nextParams.toString().length > 0 ? `${pathname}?${nextParams.toString()}` : pathname;

    if (action === "push") {
      router.push(nextUrl, { scroll: false });
      return;
    }

    router.replace(nextUrl, { scroll: false });
  };

  const handleModeSelect = (mode: MapMode) => {
    navigate(withUpdatedRouteState(baseSearchParams, { mode, segment: null }), "push");
  };

  const handleSegmentSelect = (segmentId: string) => {
    navigate(withUpdatedRouteState(baseSearchParams, { segment: segmentId }), "push");
  };

  const handleViewportCommit = ({
    lat,
    lng,
    z,
    bbox,
  }: {
    lat: number;
    lng: number;
    z: number;
    bbox: Bbox;
  }) => {
    setVisibleBbox(bbox);
    navigate(withUpdatedRouteState(baseSearchParams, { lat, lng, z }), "replace");
  };

  const handleClearSelection = () => {
    navigate(withUpdatedRouteState(baseSearchParams, { segment: null }), "push");
  };

  return (
    <section className="map-layout" aria-labelledby="map-explorer-title">
      <div className="card map-stage">
        <div className="map-stage-header">
          <div style={{ display: "grid", gap: 8 }}>
            <span className="eyebrow">{municipality ? municipality.name : "Nova Scotia overview"}</span>
            <div id="map-explorer-title" className="headline" style={{ fontSize: "clamp(2rem, 4vw, 3.4rem)" }}>
              Community road quality
            </div>
            <p className="lede" style={{ margin: 0, maxWidth: 58 + "ch" }}>
              {modeSummaryCopy[routeState.mode]}
            </p>
            <MunicipalitySearch activeMode={routeState.mode} currentQuery={routeState.q} />
          </div>
          <ModeSwitcher activeMode={routeState.mode} onSelect={handleModeSelect} />
        </div>

        <RoadQualityMapView
          municipality={municipality}
          mode={routeState.mode}
          routeState={routeState}
          onSegmentSelect={handleSegmentSelect}
          onViewportCommit={handleViewportCommit}
          onMapReadyChange={setMapReady}
          onMapErrorChange={setMapError}
        />

        <div className="map-stage-footer">
          <div className="pill">
            <span className={`mode-dot ${routeState.mode}`} />
            {routeState.mode === "quality"
              ? "Published quality layer"
              : routeState.mode === "potholes"
                ? "Active pothole markers"
                : "Coverage tiers"}
          </div>
          <span role="status" aria-live="polite">
            {mapError ?? (mapReady ? "Map loaded." : "Loading map surface…")}
          </span>
          <span>
            {stats
              ? `${stats.total_km_mapped.toFixed(1)} km mapped province-wide`
              : "Global stats still loading"}
          </span>
        </div>
      </div>

      <div style={{ display: "grid", gap: 18, alignContent: "start" }}>
        <SegmentDrawer
          mode={routeState.mode}
          selectedSegmentId={routeState.segment}
          visibleBbox={visibleBbox}
          onClearSelection={handleClearSelection}
        />
        <MapLegend />
      </div>
    </section>
  );
}
