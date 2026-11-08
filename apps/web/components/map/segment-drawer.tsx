"use client";

import { useEffect, useRef, useState } from "react";

import {
  getPotholes,
  getSegmentDetail,
  isPotholeBboxWithinLookupCap,
  type ApiResult,
  type Bbox,
  type PotholeRow,
  type SegmentDetail,
} from "@/lib/api/client";
import { formatCalendarDate, formatCount, formatDecimal } from "@/lib/format";
import type { MapMode } from "@/lib/url-state";

type SegmentDrawerProps = {
  mode: MapMode;
  selectedSegmentId: string | null;
  visibleBbox: Bbox | null;
  topPotholes: PotholeRow[];
  /** True when the top-potholes list failed to load (not merely empty). */
  topPotholesUnavailable?: boolean;
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
  topPotholesUnavailable?: boolean;
  isLoading: boolean;
  errorMessage: string | null;
  isPotholeViewportTooWide?: boolean;
  onClearSelection: () => void;
  onPotholeLocate: (pothole: PotholeRow) => void;
  isOpen?: boolean;
  onClose?: () => void;
};

export const ROAD_NOT_PUBLISHED_MESSAGE =
  "This road doesn't have enough different drivers yet to publish details.";
export const ROAD_UNAVAILABLE_MESSAGE = "Road details are unavailable right now. Try again shortly.";
export const POTHOLES_UNAVAILABLE_MESSAGE = "Pothole data is unavailable right now. Try again shortly.";

/** Maps a failed segment-detail read to visitor-facing copy; null means "ignore" (aborted). */
export function segmentDetailErrorMessage(result: Extract<ApiResult<unknown>, { ok: false }>): string | null {
  if (result.reason === "aborted") {
    return null;
  }
  if (result.reason === "http" && result.status === 404) {
    return ROAD_NOT_PUBLISHED_MESSAGE;
  }
  return ROAD_UNAVAILABLE_MESSAGE;
}

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
  topPotholesUnavailable = false,
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

    void getSegmentDetail(selectedSegmentId, { signal: controller.signal })
      .then((result) => {
        if (controller.signal.aborted) {
          return;
        }

        if (!result.ok) {
          setDetail(null);
          setErrorMessage(segmentDetailErrorMessage(result));
          return;
        }

        setDetail(result.data);
      })
      .catch(() => {
        if (!controller.signal.aborted) {
          setDetail(null);
          setErrorMessage(ROAD_UNAVAILABLE_MESSAGE);
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

    void getPotholes(visibleBbox, { signal: controller.signal })
      .then((result) => {
        if (controller.signal.aborted) {
          return;
        }

        if (!result.ok) {
          setPotholes([]);
          setErrorMessage(result.reason === "aborted" ? null : POTHOLES_UNAVAILABLE_MESSAGE);
          return;
        }

        setPotholes(result.data.potholes.slice(0, 6));
      })
      .catch(() => {
        if (!controller.signal.aborted) {
          setPotholes([]);
          setErrorMessage(POTHOLES_UNAVAILABLE_MESSAGE);
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
      topPotholesUnavailable={topPotholesUnavailable}
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
  topPotholesUnavailable = false,
  isLoading,
  errorMessage,
  isPotholeViewportTooWide = false,
  onClearSelection,
  onPotholeLocate,
  isOpen = true,
  onClose,
}: SegmentDrawerPanelProps) {
  const handleClose = onClose ?? onClearSelection;
  const closeButtonRef = useRef<HTMLButtonElement | null>(null);
  const asideRef = useRef<HTMLElement | null>(null);
  // The parent passes a new close callback on every render (and the map
  // re-renders on every `moveend`), so effects read it through a ref instead
  // of depending on it — otherwise they re-run and steal focus constantly.
  const handleCloseRef = useRef(handleClose);
  useEffect(() => {
    handleCloseRef.current = handleClose;
  });

  // Move focus into the drawer only when it transitions to open, and hand it
  // back to whatever had focus before once it closes.
  useEffect(() => {
    if (!isOpen) {
      return;
    }

    const previouslyFocused = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    closeButtonRef.current?.focus();

    return () => {
      const aside = asideRef.current;
      if (previouslyFocused && aside && aside.contains(document.activeElement)) {
        previouslyFocused.focus();
      }
    };
  }, [isOpen]);

  // Escape closes the drawer, unless something else already handled the key
  // or it came from inside a dialog (e.g. the feedback form, whose own Escape
  // must close only itself and keep its draft).
  useEffect(() => {
    if (!isOpen) {
      return;
    }

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) {
        return;
      }
      if (isInsideDialog(event.target)) {
        return;
      }
      handleCloseRef.current();
    };

    document.addEventListener("keydown", handleKeyDown);
    return () => {
      document.removeEventListener("keydown", handleKeyDown);
    };
  }, [isOpen]);

  const renderPotholeRows = (rows: PotholeRow[], label: string) => (
    <div className="pothole-list" aria-label={label}>
      {rows.map((pothole, index) => (
        <article key={pothole.id} className="pothole-row">
          <div className="pothole-row__rank">#{index + 1}</div>
          <div className="pothole-row__meta">
            <strong>
              {formatCount(pothole.confirmation_count)} confirmation{pothole.confirmation_count === 1 ? "" : "s"} ·
              magnitude {formatDecimal(pothole.magnitude, 1)}
            </strong>
            <span>
              Last seen {formatCalendarDate(pothole.last_confirmed_at) ?? "date unavailable"} ·{" "}
              {formatDecimal(pothole.lat, 4)}°N,{" "}
              {formatDecimal(absOrNull(pothole.lng), 4)}°W
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
          <span className="eyebrow">{mode === "potholes" ? "Loading potholes" : "Loading road"}</span>
          <strong>
            {mode === "potholes"
              ? "Fetching active pothole reports for this map view"
              : "Fetching road details"}
          </strong>
          <span className="lede">The drawer will fill without shifting the rest of the map layout.</span>
        </div>
      );
    }

    if (errorMessage) {
      return (
        <div className="drawer-state">
          <span className="eyebrow">{mode === "potholes" ? "Potholes unavailable" : "Road unavailable"}</span>
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
              {topPotholesUnavailable ? " The province-wide top list is unavailable right now." : null}
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
          <span className="eyebrow">Road detail</span>
          <strong>
            {mode === "quality"
              ? "Select a road to inspect"
              : "Coverage view"}
          </strong>
          <span className="lede">
            {mode === "quality"
              ? "Click a highlighted road to inspect category, confidence, trend, and pothole context."
              : "Coverage highlights where the public map has enough data to publish road conditions."}
          </span>
        </div>
      );
    }

    const aggregate = detail.aggregate;
    const summary = [
      aggregate?.category ? categoryLabel[aggregate.category] : null,
      aggregate?.confidence ? confidenceLabel[aggregate.confidence] : null,
      aggregate?.trend ? trendLabel[aggregate.trend] : null,
    ].filter((part): part is string => Boolean(part));
    const lastReading = formatCalendarDate(aggregate?.last_reading_at);

    return (
      <>
        <div style={{ display: "grid", gap: 8 }}>
          <span className="eyebrow">{detail.municipality ?? "Nova Scotia"}</span>
          <h2 style={{ margin: 0, fontSize: "1.7rem", lineHeight: 1.05 }}>
            {detail.road_name ?? "Unnamed road"}
          </h2>
          {summary.length > 0 ? (
            <p className="lede" style={{ margin: 0 }}>
              {summary.join(" · ")}
            </p>
          ) : null}
        </div>

        <div className="drawer-grid" aria-label="Road detail stats">
          <Metric label="Roughness score" value={formatDecimal(aggregate?.avg_roughness_score, 2)} />
          <Metric label="Drive samples" value={formatCount(aggregate?.total_readings)} />
          <Metric label="Drivers" value={formatCount(aggregate?.unique_contributors)} />
          <Metric label="Potholes" value={formatCount(aggregate?.pothole_count)} />
          <Metric label="Road type" value={detail.road_type ?? "Unknown"} />
          <Metric label="Surface" value={detail.surface_type ?? "Unknown"} />
        </div>

        <div className="drawer-callout">
          <span className="eyebrow">Trust</span>
          <strong>
            {lastReading ? `Last community reading on ${lastReading}` : "Last reading date not available"}
          </strong>
          <span className="lede">
            Dates are rounded to the day. Scores may change as more drivers cover the same road.
          </span>
        </div>
      </>
    );
  };

  const headingLabel =
    mode === "potholes"
      ? "Pothole map"
      : detail?.road_name ?? (selectedSegmentId ? "Loading road" : "Road detail");
  const drawerVariant = mode === "potholes" ? "pothole-panel" : "detail";

  return (
    <>
      {mode === "potholes" ? null : (
        <div
          className="drawer-backdrop"
          data-open={isOpen}
          aria-hidden={!isOpen}
          inert={!isOpen ? true : undefined}
          onClick={onClose}
        />
      )}
      <aside
        ref={asideRef}
        className="drawer"
        data-variant={drawerVariant}
        data-open={isOpen}
        aria-hidden={!isOpen}
        inert={!isOpen ? true : undefined}
        aria-live="polite"
        aria-busy={isLoading}
        role="complementary"
      >
        <div className="drawer__header">
          <div style={{ display: "grid", gap: 2 }}>
            <span className="eyebrow">
              {mode === "potholes" ? "Potholes mode" : detail?.municipality ?? "Road"}
            </span>
            <strong style={{ fontSize: "1.05rem", lineHeight: 1.2 }}>{headingLabel}</strong>
          </div>
          <button
            ref={closeButtonRef}
            type="button"
            className="drawer-close"
            onClick={handleClose}
            aria-label={mode === "potholes" ? "Close pothole panel" : "Close road detail panel"}
          >
            ×
          </button>
        </div>

        <div className="drawer__body">{renderBody()}</div>

        <div className="drawer__footer">
          <button type="button" className="secondary-button" onClick={onClearSelection}>
            {mode === "potholes" ? "Reset map focus" : "Clear selection"}
          </button>
        </div>
      </aside>
    </>
  );
}

function isInsideDialog(target: EventTarget | null): boolean {
  return target instanceof Element && target.closest("dialog") !== null;
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="metric-card">
      <span className="eyebrow">{label}</span>
      <strong>{value}</strong>
    </div>
  );
}

function absOrNull(value: number | null | undefined): number | null {
  if (value === null || value === undefined || !Number.isFinite(value)) {
    return null;
  }
  return Math.abs(value);
}
