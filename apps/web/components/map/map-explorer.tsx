"use client";

import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { startTransition, useState } from "react";

import type { Bbox, PotholeRow, PublicStats } from "@/lib/api/client";
import type { MunicipalityConfig } from "@/lib/municipality-manifest";
import {
  parseViewportState,
  searchParamRecordToUrlSearchParams,
  withUpdatedRouteState,
  type MapMode,
  type SearchParamRecord,
} from "@/lib/url-state";

import { MapStatStrip } from "./map-stat-strip";
import { ModeSwitcher } from "./mode-switcher";
import { MunicipalitySearch } from "./municipality-search";
import { MapLegend } from "./map-legend";
import { RoadQualityMapView } from "./road-quality-map-view";
import { SegmentDrawer } from "./segment-drawer";

type MapExplorerProps = {
  municipality?: MunicipalityConfig | null;
  searchParams?: SearchParamRecord;
  stats: PublicStats | null;
  topPotholes: PotholeRow[];
};

export function MapExplorer({ municipality, searchParams = {}, stats, topPotholes }: MapExplorerProps) {
  const pathname = usePathname();
  const router = useRouter();
  const liveSearchParams = useSearchParams();
  const [, setMapReady] = useState(false);
  const [mapError, setMapError] = useState<string | null>(null);
  const [visibleBbox, setVisibleBbox] = useState<Bbox | null>(null);
  const [isDrawerDismissed, setIsDrawerDismissed] = useState(false);

  const baseSearchParams =
    liveSearchParams.size > 0
      ? new URLSearchParams(liveSearchParams)
      : searchParamRecordToUrlSearchParams(searchParams);
  const routeState = parseViewportState(baseSearchParams);

  const navigate = (nextParams: URLSearchParams) => {
    const nextQuery = nextParams.toString();
    const nextUrl = nextQuery.length > 0 ? `${pathname}?${nextQuery}` : pathname;
    const currentQuery = liveSearchParams.toString();
    const currentUrl = currentQuery.length > 0 ? `${pathname}?${currentQuery}` : pathname;
    if (nextUrl === currentUrl) {
      return;
    }

    startTransition(() => {
      router.push(nextUrl, { scroll: false });
    });
  };

  const handleModeSelect = (mode: MapMode) => {
    setIsDrawerDismissed(false);
    navigate(withUpdatedRouteState(baseSearchParams, { mode, segment: null, lat: null, lng: null, z: null }));
  };

  const handleSegmentSelect = (segmentId: string) => {
    setIsDrawerDismissed(false);
    navigate(withUpdatedRouteState(baseSearchParams, { segment: segmentId }));
  };

  const handleViewportCommit = ({
    bbox,
  }: {
    lat: number;
    lng: number;
    z: number;
    bbox: Bbox;
  }) => {
    const normalizedBbox = normalizeBbox(bbox);
    setVisibleBbox((current) => {
      if (current && bboxKey(current) === bboxKey(normalizedBbox)) {
        return current;
      }

      return normalizedBbox;
    });
  };

  const handleClearSelection = () => {
    setIsDrawerDismissed(false);
    navigate(withUpdatedRouteState(baseSearchParams, { segment: null }));
  };

  const handleDrawerClose = () => {
    if (routeState.segment) {
      handleClearSelection();
      return;
    }

    setIsDrawerDismissed(true);
  };

  const handlePotholeLocate = (pothole: PotholeRow) => {
    setIsDrawerDismissed(false);
    navigate(
      withUpdatedRouteState(baseSearchParams, {
        mode: "potholes",
        segment: null,
        lat: pothole.lat,
        lng: pothole.lng,
        z: 14.4,
      }),
    );
  };

  const drawerOpen = !isDrawerDismissed && (routeState.mode === "potholes" || Boolean(routeState.segment));

  const headlineTitle = municipality
    ? `Road quality in ${municipality.name}`
    : "Nova Scotia's roads, scored by the people who drive them";
  const headlineLede = municipality
    ? `Community-reported road quality across ${municipality.name}, refreshed nightly.`
    : "Every line on this map is data from real drivers — passively collected, privately filtered, recomputed nightly.";

  return (
    <section className="map-explorer map-explorer--overlay" aria-labelledby="map-explorer-title">
      <div className="map-stage-hero">
        <RoadQualityMapView
          municipality={municipality}
          mode={routeState.mode}
          routeState={routeState}
          mapBounds={stats?.map_bounds ?? null}
          mapFocusBounds={stats?.focus_bounds ?? stats?.map_bounds ?? null}
          potholeBounds={stats?.pothole_bounds ?? null}
          topPotholes={topPotholes}
          onSegmentSelect={handleSegmentSelect}
          onViewportCommit={handleViewportCommit}
          onMapReadyChange={setMapReady}
          onMapErrorChange={setMapError}
        />

        <div className="map-overlay map-headline">
          <div className="card">
            <span className="eyebrow page-header__eyebrow">
              {municipality ? municipality.name : "Live community map"}
            </span>
            <h1 id="map-explorer-title">{headlineTitle}</h1>
            <p>{headlineLede}</p>
            {municipality ? (
              <div className="map-headline__actions">
                <a href="/" className="secondary-button" aria-label="Switch to province-wide view">
                  Province-wide view
                </a>
              </div>
            ) : null}
          </div>
        </div>

        <div className="map-overlay map-search">
          <MunicipalitySearch activeMode={routeState.mode} currentQuery={routeState.q} />
        </div>

        <MapStatStrip stats={stats} />

        <div className="map-overlay mode-switcher-floating">
          <ModeSwitcher activeMode={routeState.mode} onSelect={handleModeSelect} />
        </div>

        <div className="map-overlay map-legend-floating">
          <MapLegend mode={routeState.mode} />
        </div>

        {mapError ? (
          <div className="map-overlay map-error" role="status" aria-live="polite">
            <div className="pill pill-soft">{mapError}</div>
          </div>
        ) : null}
      </div>

      <SegmentDrawer
        mode={routeState.mode}
        selectedSegmentId={routeState.segment}
        visibleBbox={visibleBbox}
        topPotholes={topPotholes}
        onClearSelection={handleClearSelection}
        onPotholeLocate={handlePotholeLocate}
        isOpen={drawerOpen}
        onClose={handleDrawerClose}
      />
    </section>
  );
}

function normalizeBbox(bbox: Bbox): Bbox {
  return {
    minLng: roundBboxCoordinate(bbox.minLng),
    minLat: roundBboxCoordinate(bbox.minLat),
    maxLng: roundBboxCoordinate(bbox.maxLng),
    maxLat: roundBboxCoordinate(bbox.maxLat),
  };
}

function bboxKey(bbox: Bbox): string {
  return `${bbox.minLng},${bbox.minLat},${bbox.maxLng},${bbox.maxLat}`;
}

function roundBboxCoordinate(value: number): number {
  return Number(value.toFixed(4));
}
