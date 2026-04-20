import Link from "next/link";

import type { WorstSegmentsResponse } from "@/lib/api/client";
import { getMunicipalityByName, municipalityManifest } from "@/lib/municipality-manifest";

type WorstRoadsShellProps = {
  municipalityName: string | null;
  limit: number;
  result: WorstSegmentsResponse | null;
};

const categoryLabel: Record<string, string> = {
  smooth: "Smooth",
  fair: "Fair",
  rough: "Rough",
  very_rough: "Very rough",
  unpaved: "Unpaved",
};

const confidenceLabel: Record<string, string> = {
  low: "Low confidence",
  medium: "Medium confidence",
  high: "High confidence",
};

export function WorstRoadsShell({ municipalityName, limit, result }: WorstRoadsShellProps) {
  return (
    <section
      style={{
        display: "grid",
        gap: 18,
      }}
    >
      <div className="card" style={{ padding: 22, display: "grid", gap: 10 }}>
        <span className="eyebrow">Ranked public report</span>
        <div className="headline" style={{ fontSize: "clamp(1.8rem, 3vw, 3rem)" }}>
          Worst Roads
        </div>
        <p className="lede" style={{ margin: 0 }}>
          Rankings are based on published community averages and may shift as more drivers contribute data.
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
              <span className="eyebrow">Municipality</span>
              <select name="municipality" defaultValue={municipalityName ?? ""} style={selectStyle}>
                <option value="">All tracked municipalities</option>
                {municipalityManifest.map((municipality) => (
                  <option key={municipality.slug} value={municipality.name}>
                    {municipality.name}
                  </option>
                ))}
              </select>
            </label>

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
            {result?.rows.length ? (
              result.rows.map((row) => {
                const municipality = row.municipality ? getMunicipalityByName(row.municipality) : null;
                const locateHref =
                  municipality
                    ? `/municipality/${municipality.slug}?mode=quality&segment=${row.segment_id}`
                    : `/?mode=quality&segment=${row.segment_id}`;

                return (
                  <article
                    key={row.segment_id}
                    style={{
                      display: "grid",
                      gridTemplateColumns: "56px minmax(0, 1fr)",
                      gap: 14,
                      padding: 14,
                      borderRadius: 18,
                      border: "1px solid var(--rs-border)",
                      background: row.rank === 1 ? "rgba(214,108,53,0.09)" : "var(--rs-surface-strong)",
                    }}
                  >
                    <strong style={{ fontSize: "1.4rem" }}>#{row.rank}</strong>
                    <div style={{ display: "grid", gap: 6 }}>
                      <strong>{row.road_name ?? "Unnamed road"}</strong>
                      <span style={{ color: "var(--rs-text-muted)" }}>
                        {row.municipality ?? "Nova Scotia"} · {categoryLabel[row.category] ?? row.category} ·{" "}
                        {confidenceLabel[row.confidence] ?? row.confidence} · {row.trend}
                      </span>
                      <span style={{ color: "var(--rs-text-muted)" }}>
                        Score {row.avg_roughness_score.toFixed(2)} · {row.pothole_count} potholes ·{" "}
                        {row.total_readings} readings
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
                <span className="eyebrow">No published rows</span>
                <strong>No public worst-road ranking is available for this filter yet.</strong>
                <span className="lede">
                  Try a broader municipality selection or a smaller report limit after more contributors have mapped the area.
                </span>
              </div>
            )}
          </div>
        </div>

        <aside className="card" style={{ padding: 18, display: "grid", gap: 12, alignContent: "start" }}>
          <span className="eyebrow">Report framing</span>
          <strong>Public explanation belongs beside the ranking, not hidden in a help modal.</strong>
          <p className="lede" style={{ margin: 0 }}>
            This surface is for public understanding and journalism. It is not a municipal maintenance queue and should not pretend to be one.
          </p>
          <div className="drawer-callout">
            <span className="eyebrow">Freshness</span>
            <strong>{result?.generated_at ? formatDate(result.generated_at) : "Awaiting published snapshot"}</strong>
            <span className="lede">
              Rankings refresh from the published aggregate views on a 15-minute cache and nightly recompute cadence.
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
