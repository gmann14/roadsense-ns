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
    <AppShell hideTrust>
      <MapShell stats={stats} searchParams={resolvedSearchParams} />
    </AppShell>
  );
}
