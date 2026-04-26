"use client";

import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { startTransition, useState } from "react";

import type { Bbox, PotholeRow, PublicStats } from "@/lib/api/client";
import { formatSnapshotDate } from "@/lib/format";
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
  topPotholes: PotholeRow[];
};

const modeSummaryCopy: Record<MapMode, string> = {
  quality:
    "Road quality from local test drives. Pan, zoom, or click a highlighted road for detail.",
  potholes:
    "Active potholes from manual reports and confirmed impacts.",
  coverage:
    "Where RoadSense has enough data to show a public signal.",
};

const modeLabel: Record<MapMode, string> = {
  quality: "Published quality layer",
  potholes: "Active pothole markers",
  coverage: "Coverage tiers",
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
  const statsSummary = stats
    ? `${stats.total_km_mapped.toFixed(1)} road km · ${stats.segments_scored} road sections`
    : "Stats loading";

  return (
    <section className="map-explorer" aria-labelledby="map-explorer-title">
      <header className="page-header">
        <span className="eyebrow page-header__eyebrow">
          {municipality ? municipality.name : "Nova Scotia overview"}
        </span>
        <h1 id="map-explorer-title" className="headline">
          {municipality ? `Road quality in ${municipality.name}` : "Road quality map"}
        </h1>
        <p className="page-header__lede">{modeSummaryCopy[routeState.mode]}</p>
        {municipality ? (
          <div
            style={{
              display: "flex",
              flexWrap: "wrap",
              gap: 10,
              marginTop: 6,
              alignItems: "center",
            }}
            aria-label={`Quick actions for ${municipality.name}`}
          >
            <a
              href={`/reports/worst-roads?municipality=${encodeURIComponent(municipality.name)}`}
              className="secondary-button"
            >
              Worst roads in {municipality.name}
            </a>
            <a href="/" className="secondary-button" aria-label="Switch to province-wide view">
              Province-wide view
            </a>
          </div>
        ) : null}
        <div className="trust-line" aria-label="Dataset snapshot">
          <span>
            <strong>{stats ? `${stats.total_km_mapped.toFixed(1)} km` : "—"}</strong> unique road coverage
          </span>
          <span className="trust-line-divider" aria-hidden="true" />
          <span>
            <strong>{stats ? stats.segments_scored : "—"}</strong> road sections
          </span>
          <span className="trust-line-divider" aria-hidden="true" />
          <span>
            <strong>{stats ? stats.total_readings : "—"}</strong> accepted readings
          </span>
          <span className="trust-line-divider" aria-hidden="true" />
          <span>
            Updated <strong>{formatSnapshotDate(stats?.generated_at)}</strong>
          </span>
        </div>
      </header>

      <div className="explorer-controls">
        <MunicipalitySearch activeMode={routeState.mode} currentQuery={routeState.q} />
        <ModeSwitcher activeMode={routeState.mode} onSelect={handleModeSelect} />
      </div>

      <div className="map-stage-hero">
        <RoadQualityMapView
          municipality={municipality}
          mode={routeState.mode}
          routeState={routeState}
          mapBounds={stats?.map_bounds ?? null}
          potholeBounds={stats?.pothole_bounds ?? null}
          topPotholes={topPotholes}
          onSegmentSelect={handleSegmentSelect}
          onViewportCommit={handleViewportCommit}
          onMapReadyChange={setMapReady}
          onMapErrorChange={setMapError}
        />

        <div className="map-status-strip" role="status" aria-live="polite">
          <div className="pill">
            <span className={`mode-dot ${routeState.mode}`} />
            {modeLabel[routeState.mode]}
          </div>
          <div className="pill pill-soft" aria-hidden="true">
            {statsSummary}
          </div>
          {mapError ? (
            <div className="pill pill-soft" aria-hidden="true">
              {mapError}
            </div>
          ) : null}
        </div>

        <MapLegend />
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
