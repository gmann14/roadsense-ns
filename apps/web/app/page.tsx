import { AppShell } from "@/components/chrome/app-shell";
import { MapShell } from "@/components/map/map-shell";
import { DatasetJsonLd } from "@/components/seo/dataset-json-ld";
import { getPublicStats, getTopPotholes } from "@/lib/api/client";
import { pageMetadata } from "@/lib/seo";
import {
  parseViewportState,
  searchParamRecordToUrlSearchParams,
  type SearchParamRecord,
} from "@/lib/url-state";

export const metadata = pageMetadata({ path: "/" });

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
    <AppShell variant="map" dataUpdatedAt={stats?.data_updated_at ?? null}>
      <DatasetJsonLd />
      <MapShell stats={stats} searchParams={resolvedSearchParams} initialTopPotholes={topPotholes} />
    </AppShell>
  );
}
