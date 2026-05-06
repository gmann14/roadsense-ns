import { AppShell } from "@/components/chrome/app-shell";
import { MapShell } from "@/components/map/map-shell";
import { getPublicStats, getTopPotholes } from "@/lib/api/client";
import {
  parseViewportState,
  searchParamRecordToUrlSearchParams,
  type SearchParamRecord,
} from "@/lib/url-state";

export default async function HomePage({
  searchParams,
}: {
  searchParams?: Promise<SearchParamRecord>;
} = {}) {
  const resolvedSearchParams = searchParams ? await searchParams : {};
  const routeState = parseViewportState(searchParamRecordToUrlSearchParams(resolvedSearchParams));
  const shouldLoadTopPotholes = routeState.mode === "potholes";
  const [stats, topPotholes] = await Promise.all([
    getPublicStats(),
    shouldLoadTopPotholes ? getTopPotholes(100) : Promise.resolve(null),
  ]);

  return (
    <AppShell variant="map" freshness={stats?.generated_at ?? null}>
      <MapShell
        stats={stats}
        searchParams={resolvedSearchParams}
        topPotholes={topPotholes?.potholes ?? []}
      />
    </AppShell>
  );
}
