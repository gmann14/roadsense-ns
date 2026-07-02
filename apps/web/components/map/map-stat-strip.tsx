import type { PublicStats } from "@/lib/api/client";

type MapStatStripProps = {
  stats: PublicStats | null;
};

const PLACEHOLDER = "—";

function formatStat(value: number | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(value)) {
    return PLACEHOLDER;
  }
  return value.toLocaleString();
}

function formatRoundedStat(value: number | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(value)) {
    return PLACEHOLDER;
  }
  return Math.round(value).toLocaleString();
}

export function MapStatStrip({ stats }: MapStatStripProps) {
  return (
    <div className="map-overlay stat-strip" aria-label="Province-wide stats">
      <StatCard label="Roads mapped" value={formatRoundedStat(stats?.total_km_mapped)} unit="km" />
      <StatCard label="Municipalities covered" value={formatStat(stats?.municipalities_covered)} />
      <StatCard label="Pothole reports" value={formatStat(stats?.active_potholes)} unit="active" />
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
