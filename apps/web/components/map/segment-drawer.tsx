"use client";

import { useEffect, useState } from "react";

import {
  getPotholes,
  getSegmentDetail,
  isPotholeBboxWithinLookupCap,
  type Bbox,
  type PotholeRow,
  type SegmentDetail,
} from "@/lib/api/client";
import type { MapMode } from "@/lib/url-state";

type SegmentDrawerProps = {
  mode: MapMode;
  selectedSegmentId: string | null;
  visibleBbox: Bbox | null;
  topPotholes: PotholeRow[];
  onClearSelection: () => void;
  onPotholeLocate: (pothole: PotholeRow) => void;
  isOpen?: boolean;
  onClose?: () => void;
};

type SegmentDrawerPanelProps = {
  mode: MapMode;
  selectedSegmentId: string | null;
  detail: SegmentDetail | null;
  potholes: PotholeRow[];
  topPotholes: PotholeRow[];
  isLoading: boolean;
  errorMessage: string | null;
  isPotholeViewportTooWide?: boolean;
  onClearSelection: () => void;
  onPotholeLocate: (pothole: PotholeRow) => void;
  isOpen?: boolean;
  onClose?: () => void;
};

const categoryLabel: Record<SegmentDetail["aggregate"]["category"], string> = {
  smooth: "Smooth",
  fair: "Fair",
  rough: "Rough",
  very_rough: "Very rough",
  unpaved: "Unpaved",
};

const confidenceLabel: Record<SegmentDetail["aggregate"]["confidence"], string> = {
  low: "Low confidence",
  medium: "Medium confidence",
  high: "High confidence",
};

const trendLabel: Record<SegmentDetail["aggregate"]["trend"], string> = {
  improving: "Improving",
  stable: "Stable",
  worsening: "Worsening",
};

export function SegmentDrawer({
  mode,
  selectedSegmentId,
  visibleBbox,
  topPotholes,
  onClearSelection,
  onPotholeLocate,
  isOpen,
  onClose,
}: SegmentDrawerProps) {
  const [detail, setDetail] = useState<SegmentDetail | null>(null);
  const [potholes, setPotholes] = useState<PotholeRow[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  useEffect(() => {
    if (mode !== "quality") {
      setDetail(null);
      return;
    }

    setPotholes([]);

    if (!selectedSegmentId) {
      setDetail(null);
      setIsLoading(false);
      setErrorMessage(null);
      return;
    }

    const controller = new AbortController();
    setIsLoading(true);
    setErrorMessage(null);

    void getSegmentDetail(selectedSegmentId)
      .then((result) => {
        if (controller.signal.aborted) {
          return;
        }

        if (!result) {
          setDetail(null);
          setErrorMessage("We could not load details for this road segment.");
          return;
        }

        setDetail(result);
      })
      .catch(() => {
        if (!controller.signal.aborted) {
          setDetail(null);
          setErrorMessage("We could not load details for this road segment.");
        }
      })
      .finally(() => {
        if (!controller.signal.aborted) {
          setIsLoading(false);
        }
      });

    return () => {
      controller.abort();
    };
  }, [mode, selectedSegmentId]);

  useEffect(() => {
    if (mode !== "potholes") {
      setPotholes([]);
      return;
    }

    if (!visibleBbox) {
      setPotholes([]);
      setIsLoading(false);
      return;
    }

    if (!isPotholeBboxWithinLookupCap(visibleBbox)) {
      setPotholes([]);
      setIsLoading(false);
      setErrorMessage(null);
      return;
    }

    const controller = new AbortController();
    setIsLoading(true);
    setErrorMessage(null);

    void getPotholes(visibleBbox)
      .then((response) => {
        if (controller.signal.aborted) {
          return;
        }

        setPotholes((response?.potholes ?? []).slice(0, 6));
      })
      .catch(() => {
        if (!controller.signal.aborted) {
          setPotholes([]);
          setErrorMessage("We could not load potholes for this map view.");
        }
      })
      .finally(() => {
        if (!controller.signal.aborted) {
          setIsLoading(false);
        }
      });

    return () => {
      controller.abort();
    };
  }, [mode, visibleBbox]);

  const resolvedIsOpen = isOpen ?? Boolean(selectedSegmentId || mode === "potholes");
  const isPotholeViewportTooWide =
    mode === "potholes" && visibleBbox !== null && !isPotholeBboxWithinLookupCap(visibleBbox);
  const handleClose = () => {
    if (onClose) {
      onClose();
      return;
    }
    onClearSelection();
  };

  return (
    <SegmentDrawerPanel
      mode={mode}
      selectedSegmentId={selectedSegmentId}
      detail={detail}
      potholes={potholes}
      topPotholes={topPotholes}
      isLoading={isLoading}
      errorMessage={errorMessage}
      isPotholeViewportTooWide={isPotholeViewportTooWide}
      onClearSelection={onClearSelection}
      onPotholeLocate={onPotholeLocate}
      isOpen={resolvedIsOpen}
      onClose={handleClose}
    />
  );
}

export function SegmentDrawerPanel({
  mode,
  selectedSegmentId,
  detail,
  potholes,
  topPotholes,
  isLoading,
  errorMessage,
  isPotholeViewportTooWide = false,
  onClearSelection,
  onPotholeLocate,
  isOpen = true,
  onClose,
}: SegmentDrawerPanelProps) {
  const handleClose = onClose ?? onClearSelection;
  const renderPotholeRows = (rows: PotholeRow[], label: string) => (
    <div className="pothole-list" aria-label={label}>
      {rows.map((pothole, index) => (
        <article key={pothole.id} className="pothole-row">
          <div className="pothole-row__rank">#{index + 1}</div>
          <div className="pothole-row__meta">
            <strong>
              {pothole.confirmation_count} confirmation{pothole.confirmation_count === 1 ? "" : "s"} · magnitude{" "}
              {pothole.magnitude.toFixed(1)}
            </strong>
            <span>
              Last seen {formatRelativeDate(pothole.last_confirmed_at)} · {pothole.lat.toFixed(4)}°N,{" "}
              {Math.abs(pothole.lng).toFixed(4)}°W
            </span>
          </div>
          <button
            type="button"
            className="secondary-button pothole-row__action"
            onClick={() => onPotholeLocate(pothole)}
          >
            Show on map
          </button>
        </article>
      ))}
    </div>
  );

  const renderBody = () => {
    if (isLoading) {
      return (
        <div className="drawer-state">
          <span className="eyebrow">{mode === "potholes" ? "Loading potholes" : "Loading segment"}</span>
          <strong>
            {mode === "potholes"
              ? "Fetching active pothole reports for this map view"
              : `Fetching community detail for ${selectedSegmentId}`}
          </strong>
          <span className="lede">The drawer will fill without shifting the rest of the map layout.</span>
        </div>
      );
    }

    if (errorMessage) {
      return (
        <div className="drawer-state">
          <span className="eyebrow">{mode === "potholes" ? "Potholes unavailable" : "Segment unavailable"}</span>
          <strong>{errorMessage}</strong>
        </div>
      );
    }

    if (mode === "potholes") {
      const leaderboardRows = topPotholes.slice(0, 6);

      if (isPotholeViewportTooWide) {
        if (leaderboardRows.length > 0) {
          return (
            <>
              <div className="drawer-state">
                <span className="eyebrow">Pothole leaderboard</span>
                <strong>Top active potholes</strong>
                <span className="lede">
                  This viewport is wider than the live list cap, so the side panel is showing the strongest active
                  reports. The map stays usable; choose a row to zoom to that marker.
                </span>
              </div>
              {renderPotholeRows(leaderboardRows, "Top active potholes")}
            </>
          );
        }

        return (
          <div className="drawer-state">
            <span className="eyebrow">Pothole map</span>
            <strong>Zoom the map to inspect active potholes.</strong>
            <span className="lede">
              Live pothole lists are capped to a roughly 10 km viewport so the public map stays responsive.
            </span>
          </div>
        );
      }

      if (potholes.length === 0) {
        if (leaderboardRows.length > 0) {
          return (
            <>
              <div className="drawer-state">
                <span className="eyebrow">Pothole leaderboard</span>
                <strong>No active potholes in this viewport yet.</strong>
                <span className="lede">
                  Showing the strongest active reports elsewhere. Click a row to jump the map to that marker.
                </span>
              </div>
              {renderPotholeRows(leaderboardRows, "Top active potholes")}
            </>
          );
        }

        return (
          <div className="drawer-state">
            <span className="eyebrow">Pothole list</span>
            <strong>No active potholes are published in this view yet.</strong>
            <span className="lede">
              Pan or zoom the map to refresh the viewport. This list updates from recent community-confirmed impacts,
              not municipal work orders.
            </span>
          </div>
        );
      }

      return (
        <>
          <div className="drawer-state">
            <span className="eyebrow">Pothole list</span>
            <strong>Active potholes in this view</strong>
            <span className="lede">
              Showing recent community-confirmed impacts inside the current viewport. Click a row to center its marker.
            </span>
          </div>

          {renderPotholeRows(potholes, "Potholes in current viewport")}
        </>
      );
    }

    if (!detail) {
      return (
        <div className="drawer-state">
          <span className="eyebrow">Segment drawer</span>
          <strong>
            {mode === "quality"
              ? "Select a road to inspect"
                : "Coverage mode lands in the next slice"}
          </strong>
          <span className="lede">
            {mode === "quality"
              ? "Click a published road line on the map to inspect category, confidence, trend, and pothole context."
              : "Route-state switching is live already, but the alternate map source for this mode is still queued next in the implementation plan."}
          </span>
        </div>
      );
    }

    return (
      <>
        <div style={{ display: "grid", gap: 8 }}>
          <span className="eyebrow">{detail.municipality ?? "Nova Scotia"}</span>
          <h2 style={{ margin: 0, fontSize: "1.7rem", lineHeight: 1.05 }}>
            {detail.road_name ?? "Unnamed road"}
          </h2>
          <p className="lede" style={{ margin: 0 }}>
            {categoryLabel[detail.aggregate.category]} · {confidenceLabel[detail.aggregate.confidence]} ·{" "}
            {trendLabel[detail.aggregate.trend]}
          </p>
        </div>

        <div className="drawer-grid" aria-label="Segment detail stats">
          <Metric label="Roughness score" value={detail.aggregate.avg_roughness_score.toFixed(2)} />
          <Metric label="Readings" value={String(detail.aggregate.total_readings)} />
          <Metric label="Contributors" value={String(detail.aggregate.unique_contributors)} />
          <Metric label="Potholes" value={String(detail.aggregate.pothole_count)} />
          <Metric label="Road type" value={detail.road_type} />
          <Metric label="Surface" value={detail.surface_type ?? "Unknown"} />
        </div>

        <div className="drawer-callout">
          <span className="eyebrow">Trust</span>
          <strong>
            Last community reading {detail.aggregate.last_reading_at ? formatRelativeDate(detail.aggregate.last_reading_at) : "not available"}
          </strong>
          <span className="lede">
            Aggregates are refreshed nightly and may continue to evolve as more contributors drive this segment.
          </span>
        </div>
      </>
    );
  };

  const headingLabel =
    mode === "potholes"
      ? "Pothole map"
      : detail?.road_name ?? (selectedSegmentId ? "Loading segment" : "Segment detail");
  const drawerVariant = mode === "potholes" ? "pothole-panel" : "detail";

  return (
    <>
      {mode === "potholes" ? null : (
        <div
          className="drawer-backdrop"
          data-open={isOpen}
          aria-hidden={!isOpen}
          onClick={onClose}
        />
      )}
      <aside
        className="drawer"
        data-variant={drawerVariant}
        data-open={isOpen}
        aria-hidden={!isOpen}
        aria-live="polite"
        aria-busy={isLoading}
        role="complementary"
      >
        <div className="drawer__header">
          <div style={{ display: "grid", gap: 2 }}>
            <span className="eyebrow">
              {mode === "potholes" ? "Potholes mode" : detail?.municipality ?? "Segment"}
            </span>
            <strong style={{ fontSize: "1.05rem", lineHeight: 1.2 }}>{headingLabel}</strong>
          </div>
          <button
            type="button"
            className="drawer-close"
            onClick={handleClose}
            aria-label="Close segment detail drawer"
          >
            ×
          </button>
        </div>

        <div className="drawer__body">{renderBody()}</div>

        <div className="drawer__footer">
          <button type="button" className="secondary-button" onClick={onClearSelection}>
            {mode === "potholes" ? "Reset map focus" : "Clear selection"}
          </button>
          {mode === "potholes" ? (
            <a href="/reports/potholes" className="secondary-button">
              Full report
            </a>
          ) : null}
        </div>
      </aside>
    </>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="metric-card">
      <span className="eyebrow">{label}</span>
      <strong>{value}</strong>
    </div>
  );
}

function formatRelativeDate(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "is unavailable";
  }

  return date.toLocaleDateString("en-CA", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}
