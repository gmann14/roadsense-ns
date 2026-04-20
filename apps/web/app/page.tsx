import { AppShell } from "@/components/chrome/app-shell";
import { MapShell } from "@/components/map/map-shell";
import { getPublicStats } from "@/lib/api/client";
import type { SearchParamRecord } from "@/lib/url-state";

export default async function HomePage({
  searchParams,
}: {
  searchParams?: Promise<SearchParamRecord>;
} = {}) {
  const stats = await getPublicStats();
  const resolvedSearchParams = searchParams ? await searchParams : {};

  return (
    <AppShell
      totalKmMapped={stats ? `${stats.total_km_mapped.toFixed(1)} km` : "Stats pending"}
      municipalitiesCovered={stats ? String(stats.municipalities_covered) : "Pending"}
      freshness={stats?.generated_at ?? "Awaiting backend"}
    >
      <MapShell stats={stats} searchParams={resolvedSearchParams} />
    </AppShell>
  );
}
