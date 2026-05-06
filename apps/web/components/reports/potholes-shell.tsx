import { PotholesExplorer } from "@/components/reports/potholes-explorer";
import type { PotholeRow } from "@/lib/api/client";

type PotholesShellProps = {
  limit: number;
  rows: PotholeRow[];
  activePotholeCount: number | null;
  listUnavailable?: boolean;
  generatedAt: string | null;
};

export function PotholesShell({
  limit,
  rows,
  activePotholeCount,
  listUnavailable = false,
  generatedAt,
}: PotholesShellProps) {
  const visibleRows = rows.slice(0, limit);
  const countLabel = activePotholeCount === null ? rows.length : activePotholeCount;

  return (
    <section className="potholes-shell">
      <header className="potholes-shell__header card">
        <span className="eyebrow">Community pothole report</span>
        <h1 className="potholes-shell__heading">Most-reported potholes</h1>
        <p className="lede" style={{ margin: 0 }}>
          Ranked by how many contributors independently confirmed the same impact. These are community sightings, not a municipal maintenance queue.
        </p>
        <div className="potholes-shell__summary">
          <strong>{countLabel}</strong>
          <span>active reports · updated {formatGeneratedAt(generatedAt)}</span>
        </div>
        <form method="get" className="potholes-shell__limit-form">
          <label>
            <span className="eyebrow">Show</span>
            <select name="limit" defaultValue={String(limit)}>
              {[10, 20, 30, 50].map((candidate) => (
                <option key={candidate} value={candidate}>
                  Top {candidate}
                </option>
              ))}
            </select>
          </label>
          <button type="submit" className="secondary-button">
            Update
          </button>
        </form>
      </header>

      <PotholesExplorer
        rows={visibleRows}
        activePotholeCount={activePotholeCount}
        listUnavailable={listUnavailable}
      />
    </section>
  );
}

function formatGeneratedAt(value: string | null): string {
  if (!value) {
    return "pending";
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "pending";
  }
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Halifax",
    month: "short",
    day: "numeric",
  }).format(date);
}
