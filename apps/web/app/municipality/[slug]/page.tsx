import { notFound } from "next/navigation";

import { AppShell } from "@/components/chrome/app-shell";
import { MapShell } from "@/components/map/map-shell";
import { getPublicStats, getTopPotholes } from "@/lib/api/client";
import { getMunicipalityBySlug } from "@/lib/municipality-manifest";
import {
  parseViewportState,
  searchParamRecordToUrlSearchParams,
  type SearchParamRecord,
} from "@/lib/url-state";

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
  const [{ slug }, resolvedSearchParams] = await Promise.all([
    params,
    searchParams ?? Promise.resolve({}),
  ]);
  const municipality = getMunicipalityBySlug(slug);

  if (!municipality) {
    notFound();
  }

  const routeState = parseViewportState(searchParamRecordToUrlSearchParams(resolvedSearchParams));
  const shouldLoadTopPotholes = routeState.mode === "potholes";
  const [stats, topPotholes] = await Promise.all([
    getPublicStats(),
    shouldLoadTopPotholes ? getTopPotholes(50) : Promise.resolve(null),
  ]);

  return (
    <AppShell variant="map" freshness={stats?.generated_at ?? null}>
      <MapShell
        stats={stats}
        municipality={municipality}
        searchParams={resolvedSearchParams}
        topPotholes={topPotholes?.potholes ?? []}
      />
    </AppShell>
  );
}
