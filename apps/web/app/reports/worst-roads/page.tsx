import { AppShell } from "@/components/chrome/app-shell";
import { WorstRoadsShell } from "@/components/reports/worst-roads-shell";
import { getPublicStats, getWorstSegments } from "@/lib/api/client";
import {
  getMunicipalityBackendName,
  getMunicipalityByName,
} from "@/lib/municipality-manifest";
import type { SearchParamRecord } from "@/lib/url-state";

function firstValue(value: string | string[] | undefined): string | null {
  if (Array.isArray(value)) {
    return value[0] ?? null;
  }
  return value ?? null;
}

export default async function WorstRoadsPage({
  searchParams,
}: {
  searchParams?: Promise<SearchParamRecord>;
} = {}) {
  const resolvedSearchParams = searchParams ? await searchParams : {};
  const municipalityName = firstValue(resolvedSearchParams.municipality);
  const municipality = municipalityName ? getMunicipalityByName(municipalityName) : null;
  const backendMunicipalityName = municipality ? getMunicipalityBackendName(municipality) : municipalityName;
  const limit = Number.parseInt(firstValue(resolvedSearchParams.limit) ?? "20", 10);
  const safeLimit = Number.isInteger(limit) && limit >= 1 && limit <= 100 ? limit : 20;
  const [stats, result] = await Promise.all([
    getPublicStats(),
    getWorstSegments({
      municipality: backendMunicipalityName,
      limit: safeLimit,
    }),
  ]);

  return (
    <AppShell
      totalKmMapped="Published report"
      municipalitiesCovered={municipality?.name ?? "All tracked"}
      freshness={result?.generated_at ?? stats?.generated_at ?? "15-minute cache"}
    >
      <WorstRoadsShell
        municipalityName={municipality?.name ?? municipalityName}
        limit={safeLimit}
        result={result}
      />
    </AppShell>
  );
}
