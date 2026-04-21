import Link from "next/link";

import type { PotholeRow } from "@/lib/api/client";

type PotholesShellProps = {
  limit: number;
  rows: PotholeRow[];
  generatedAt: string | null;
};

export function PotholesShell({ limit, rows, generatedAt }: PotholesShellProps) {
  const visibleRows = rows.slice(0, limit);

  return (
    <section
      style={{
        display: "grid",
        gap: 18,
      }}
    >
      <div className="card" style={{ padding: 22, display: "grid", gap: 10 }}>
        <span className="eyebrow">Community pothole report</span>
        <div className="headline" style={{ fontSize: "clamp(1.8rem, 3vw, 3rem)" }}>
          Most-reported potholes
        </div>
        <p className="lede" style={{ margin: 0 }}>
          Ranked by how many contributors independently confirmed the same impact. These are community sightings, not a municipal maintenance queue.
        </p>
      </div>

      <div
        style={{
          display: "grid",
          gridTemplateColumns: "minmax(0, 1.2fr) minmax(280px, 0.8fr)",
          gap: 18,
        }}
      >
        <div className="card" style={{ padding: 18 }}>
          <form method="get" style={{ display: "flex", flexWrap: "wrap", gap: 12, marginBottom: 18 }}>
            <label style={{ display: "grid", gap: 6 }}>
              <span className="eyebrow">Rows</span>
              <select name="limit" defaultValue={String(limit)} style={selectStyle}>
                {[10, 20, 30, 50].map((candidate) => (
                  <option key={candidate} value={candidate}>
                    Top {candidate}
                  </option>
                ))}
              </select>
            </label>

            <button type="submit" className="secondary-button" style={{ alignSelf: "end" }}>
              Update report
            </button>
          </form>

          <div style={{ display: "grid", gap: 12 }}>
            {visibleRows.length ? (
              visibleRows.map((row, index) => {
                const rank = index + 1;
                const locateHref = `/?mode=potholes&segment=${row.segment_id}`;

                return (
                  <article
                    key={row.id}
                    style={{
                      display: "grid",
                      gridTemplateColumns: "56px minmax(0, 1fr)",
                      gap: 14,
                      padding: 14,
                      borderRadius: 18,
                      border: "1px solid var(--rs-border)",
                      background: rank === 1 ? "rgba(214,108,53,0.09)" : "var(--rs-surface-strong)",
                    }}
                  >
                    <strong style={{ fontSize: "1.4rem" }}>#{rank}</strong>
                    <div style={{ display: "grid", gap: 6 }}>
                      <strong>
                        {row.confirmation_count} confirmations · magnitude {row.magnitude.toFixed(1)}
                      </strong>
                      <span style={{ color: "var(--rs-text-muted)" }}>
                        Status {row.status} · first reported {formatRelative(row.first_reported_at)} · last confirmed{" "}
                        {formatRelative(row.last_confirmed_at)}
                      </span>
                      <span style={{ color: "var(--rs-text-muted)" }}>
                        {row.lat.toFixed(4)}°N, {Math.abs(row.lng).toFixed(4)}°W
                      </span>
                      <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
                        <Link href={locateHref} className="secondary-button">
                          Locate on map
                        </Link>
                      </div>
                    </div>
                  </article>
                );
              })
            ) : (
              <div className="drawer-callout">
                <span className="eyebrow">No published potholes</span>
                <strong>No active community potholes are published province-wide yet.</strong>
                <span className="lede">
                  Confirmations aggregate nightly. Check back after more contributors drive the same road.
                </span>
              </div>
            )}
          </div>
        </div>

        <aside className="card" style={{ padding: 18, display: "grid", gap: 12, alignContent: "start" }}>
          <span className="eyebrow">How this list is built</span>
          <strong>One pothole can be confirmed by many drivers. The more confirmations, the higher it ranks.</strong>
          <p className="lede" style={{ margin: 0 }}>
            Each row is a community-observed impact that passed on-device privacy filtering. Magnitude reflects the vertical shock recorded at the moment of impact.
          </p>
          <div className="drawer-callout">
            <span className="eyebrow">Freshness</span>
            <strong>{generatedAt ? formatDate(generatedAt) : "Awaiting published snapshot"}</strong>
            <span className="lede">
              Potholes refresh from the published viewport feed on a 15-minute cache and nightly recompute cadence.
            </span>
          </div>
        </aside>
      </div>
    </section>
  );
}

const selectStyle = {
  minWidth: 220,
  padding: "10px 12px",
  borderRadius: 12,
  border: "1px solid var(--rs-border)",
  background: "var(--rs-surface-strong)",
};

function formatDate(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "Awaiting published snapshot";
  }

  return date.toLocaleString("en-CA", {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

function formatRelative(value: string | null | undefined): string {
  if (!value) {
    return "not yet";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "not yet";
  }

  return date.toLocaleDateString("en-CA", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}
