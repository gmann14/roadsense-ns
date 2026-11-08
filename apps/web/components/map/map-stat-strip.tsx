import type { PublicStats } from "@/lib/api/client";
import { formatCount } from "@/lib/format";

type MapStatStripProps = {
  /** Null means the stats request failed, not that the counts are zero. */
  stats: PublicStats | null;
};

export function MapStatStrip({ stats }: MapStatStripProps) {
  return (
    <div className="map-overlay stat-strip" aria-label="Province-wide stats">
      <StatCard label="Roads mapped" value={formatCount(stats?.total_km_mapped)} unit="km" />
      <StatCard label="Municipalities covered" value={formatCount(stats?.municipalities_covered)} />
      <StatCard label="Pothole reports" value={formatCount(stats?.active_potholes)} unit="active" />
      {stats ? null : (
        <p className="stat-strip__notice" role="status">
          Live stats are unavailable right now.
        </p>
      )}
    </div>
  );
}

function StatCard({ label, value, unit }: { label: string; value: string; unit?: string }) {
  return (
    <div className="card" data-testid="map-stat">
      <div className="stat-row">
        <span className="stat-label">{label}</span>
        <span className="stat-value">
          {value}
          {unit ? <span className="stat-unit">{unit}</span> : null}
        </span>
      </div>
    </div>
  );
}
