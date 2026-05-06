"use client";

import Link from "next/link";
import { useState } from "react";

import type { PotholeRow } from "@/lib/api/client";

type PotholesExplorerProps = {
  rows: PotholeRow[];
  activePotholeCount: number | null;
  listUnavailable?: boolean;
};

export function PotholesExplorer({
  rows,
  activePotholeCount,
  listUnavailable = false,
}: PotholesExplorerProps) {
  const [selectedId, setSelectedId] = useState<string | null>(rows[0]?.id ?? null);

  if (rows.length === 0) {
    if (listUnavailable && activePotholeCount && activePotholeCount > 0) {
      return (
        <div className="drawer-callout">
          <span className="eyebrow">Report list unavailable</span>
          <strong>{activePotholeCount.toLocaleString()} active pothole reports exist, but the ranked list did not load.</strong>
          <span className="lede">
            The map can still show pothole reports in pothole mode. This list will reappear once the public report feed responds.
          </span>
          <Link href="/?mode=potholes" className="secondary-button">
            Open pothole map
          </Link>
        </div>
      );
    }

    return (
      <div className="drawer-callout">
        <span className="eyebrow">No published potholes</span>
        <strong>No active community potholes are published province-wide yet.</strong>
        <span className="lede">
          Confirmations aggregate nightly. Check back after more contributors drive the same road.
        </span>
      </div>
    );
  }

  const selected = rows.find((row) => row.id === selectedId) ?? rows[0];

  return (
    <div className="potholes-page">
      <ol className="potholes-list" aria-label="Most-reported potholes">
        {rows.map((row, index) => {
          const rank = index + 1;
          const isActive = row.id === selected.id;
          const locateHref = `/?mode=potholes&lat=${row.lat.toFixed(5)}&lng=${row.lng.toFixed(5)}&z=14.4`;
          return (
            <li key={row.id} className="pothole-row-item">
              <button
                type="button"
                className={`pothole-row${isActive ? " active" : ""}`}
                aria-pressed={isActive}
                aria-label={`Pothole #${rank} at ${row.lat.toFixed(4)}, ${row.lng.toFixed(4)}, ${row.confirmation_count} confirmations`}
                onClick={() => setSelectedId(row.id)}
              >
                <span className="rank">#{rank}</span>
                <span className="pothole-row__body">
                  <span className="title">
                    {coordsLabel(row)}
                  </span>
                  <span className="meta">
                    <span>magnitude {row.magnitude.toFixed(1)}</span>
                    <span className="meta-dot" aria-hidden="true" />
                    <span>last hit {formatRelative(row.last_confirmed_at)}</span>
                  </span>
                </span>
                <span className="confirm-badge">
                  <strong>{row.confirmation_count}</strong>
                  <span>conf.</span>
                </span>
              </button>
              <Link
                href={locateHref}
                className="pothole-row__locate"
                aria-label={`Locate pothole #${rank} on the main map`}
              >
                Locate ↗
              </Link>
            </li>
          );
        })}
      </ol>

      <PotholeDetailCard pothole={selected} rank={rows.findIndex((r) => r.id === selected.id) + 1} />
    </div>
  );
}

function PotholeDetailCard({ pothole, rank }: { pothole: PotholeRow; rank: number }) {
  const locateHref = `/?mode=potholes&lat=${pothole.lat.toFixed(5)}&lng=${pothole.lng.toFixed(5)}&z=14.4`;

  return (
    <aside className="pothole-detail card" aria-live="polite">
      <span className="eyebrow">Selected pothole · #{rank}</span>
      <h2 className="pothole-detail__heading" data-testid="pothole-detail-coords">
        {coordsLabel(pothole)}
      </h2>
      <p className="pothole-detail__meta">
        First reported {formatRelative(pothole.first_reported_at)} · last hit {formatRelative(pothole.last_confirmed_at)}
      </p>

      <div className="photo-slot" aria-label="Photo coming soon">
        <div className="photo-slot-frame" aria-hidden="true">
          <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">
            <rect x="3" y="5" width="18" height="14" rx="2" />
            <circle cx="12" cy="12" r="3" />
            <path d="M8 5l1.5-2h5L16 5" />
          </svg>
        </div>
        <div>
          <strong>Photo · coming soon</strong>
          <span>Drivers will be able to attach a single photo per confirmation in a future release.</span>
        </div>
      </div>

      <div className="pothole-detail__stats">
        <Stat value={pothole.confirmation_count} label="drivers have confirmed" />
        <Stat value={pothole.magnitude.toFixed(1)} unit="g" label="vertical impact" />
      </div>

      <p className="pothole-detail__callout">
        Magnitude is the vertical shock at impact, in g-force. A loose manhole feels like ~3g; a deep pothole, 5g+.
      </p>

      <div className="future-actions">
        <button
          type="button"
          className="future-btn"
          aria-label="Mark as fixed (coming soon)"
          disabled
        >
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M20 6 9 17l-5-5" />
          </svg>
          Mark as fixed
          <span className="future-tag">Soon</span>
        </button>
        <button
          type="button"
          className="future-btn"
          aria-label="Comment (coming soon)"
          disabled
        >
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
          </svg>
          Comment
          <span className="future-tag">Soon</span>
        </button>
      </div>

      <div className="pothole-detail__footer">
        <Link href={locateHref} className="secondary-button">
          Locate on main map
        </Link>
        <Link href="/methodology" className="pothole-detail__methodology-link">
          How is this measured? →
        </Link>
      </div>
    </aside>
  );
}

function Stat({ value, unit, label }: { value: string | number; unit?: string; label: string }) {
  return (
    <div className="pothole-detail__stat">
      <span className="pothole-detail__stat-value">
        {value}
        {unit ? <span className="pothole-detail__stat-unit">{unit}</span> : null}
      </span>
      <span className="pothole-detail__stat-label">{label}</span>
    </div>
  );
}

function coordsLabel(row: PotholeRow): string {
  return `${row.lat.toFixed(4)}°N, ${Math.abs(row.lng).toFixed(4)}°W`;
}

function formatRelative(value: string | null | undefined): string {
  if (!value) {
    return "not yet";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "not yet";
  }
  return new Intl.DateTimeFormat("en-CA", {
    month: "short",
    day: "numeric",
    year: "numeric",
  }).format(date);
}
