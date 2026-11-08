import type { Metadata } from "next";
import { notFound } from "next/navigation";

import { AppShell } from "@/components/chrome/app-shell";
import { MapShell } from "@/components/map/map-shell";
import { getPublicStats, getTopPotholes } from "@/lib/api/client";
import { getMunicipalityBySlug } from "@/lib/municipality-manifest";
import { pageMetadata, pageTitle } from "@/lib/seo";
import {
  parseViewportState,
  searchParamRecordToUrlSearchParams,
  type SearchParamRecord,
} from "@/lib/url-state";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>;
}): Promise<Metadata> {
  const { slug } = await params;
  const municipality = getMunicipalityBySlug(slug);

  if (!municipality) {
    return {
      title: pageTitle("Municipality not found"),
      robots: { index: false },
    };
  }

  return pageMetadata({
    path: `/municipality/${municipality.slug}`,
    title: `Road conditions in ${municipality.name}`,
    description: `Community-measured road roughness, pothole reports and coverage in ${municipality.name}, Nova Scotia, published as road-level averages from at least 3 drivers.`,
  });
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
    shouldLoadTopPotholes ? getTopPotholes(100) : Promise.resolve(null),
  ]);

  return (
    <AppShell variant="map" dataUpdatedAt={stats?.data_updated_at ?? null}>
      <MapShell
        stats={stats}
        municipality={municipality}
        searchParams={resolvedSearchParams}
        initialTopPotholes={topPotholes}
      />
    </AppShell>
  );
}
