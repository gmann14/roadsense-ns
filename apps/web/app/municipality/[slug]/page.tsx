import { notFound } from "next/navigation";

import { AppShell } from "@/components/chrome/app-shell";
import { MapShell } from "@/components/map/map-shell";
import { getPublicStats, getTopPotholes } from "@/lib/api/client";
import { getMunicipalityBySlug } from "@/lib/municipality-manifest";
import type { SearchParamRecord } from "@/lib/url-state";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  const municipality = getMunicipalityBySlug(slug);

  if (!municipality) {
    return {
      title: "Municipality not found | RoadSense NS",
    };
  }

  return {
    title: `Road conditions in ${municipality.name} | RoadSense NS`,
    description: `Explore community-reported road quality, potholes, and coverage in ${municipality.name}.`,
  };
}

export default async function MunicipalityPage({
  params,
  searchParams,
}: {
  params: Promise<{ slug: string }>;
  searchParams?: Promise<SearchParamRecord>;
}) {
  const { slug } = await params;
  const municipality = getMunicipalityBySlug(slug);
  const [stats, topPotholes] = await Promise.all([
    getPublicStats(),
    getTopPotholes(12),
  ]);
  const resolvedSearchParams = searchParams ? await searchParams : {};

  if (!municipality) {
    notFound();
  }

  return (
    <AppShell
      totalKmMapped={stats ? `${stats.total_km_mapped.toFixed(1)} km` : "Municipality focus"}
      municipalitiesCovered={municipality.name}
      freshness={stats?.generated_at ?? "Awaiting live fetch"}
    >
      <MapShell
        stats={stats}
        municipality={municipality}
        searchParams={resolvedSearchParams}
        topPotholes={topPotholes?.potholes ?? []}
      />
    </AppShell>
  );
}
