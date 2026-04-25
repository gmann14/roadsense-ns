import { AppShell } from "@/components/chrome/app-shell";
import { MapShell } from "@/components/map/map-shell";
import { getPublicStats, getTopPotholes } from "@/lib/api/client";
import type { SearchParamRecord } from "@/lib/url-state";

export default async function HomePage({
  searchParams,
}: {
  searchParams?: Promise<SearchParamRecord>;
} = {}) {
  const [stats, topPotholes] = await Promise.all([
    getPublicStats(),
    getTopPotholes(12),
  ]);
  const resolvedSearchParams = searchParams ? await searchParams : {};

  return (
    <AppShell hideTrust>
      <MapShell
        stats={stats}
        searchParams={resolvedSearchParams}
        topPotholes={topPotholes?.potholes ?? []}
      />
    </AppShell>
  );
}
