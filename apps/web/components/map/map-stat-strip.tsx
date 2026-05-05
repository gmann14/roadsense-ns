import type { PublicStats } from "@/lib/api/client";

type MapStatStripProps = {
  stats: PublicStats | null;
};

export function MapStatStrip({ stats }: MapStatStripProps) {
  return (
    <div className="map-overlay stat-strip" aria-label="Province-wide stats">
      <StatCard
        label="Roads mapped"
        value={stats ? Math.round(stats.total_km_mapped).toLocaleString() : "—"}
        unit="km"
      />
      <StatCard
        label="Municipalities covered"
        value={stats ? stats.municipalities_covered.toLocaleString() : "—"}
      />
      <StatCard
        label="Potholes tracked"
        value={stats ? stats.active_potholes.toLocaleString() : "—"}
      />
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
