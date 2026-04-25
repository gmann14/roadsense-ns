import { AppShell } from "@/components/chrome/app-shell";
import { PotholesShell } from "@/components/reports/potholes-shell";
import { getPublicStats, getTopPotholes, type PotholeRow } from "@/lib/api/client";
import type { SearchParamRecord } from "@/lib/url-state";

function firstValue(value: string | string[] | undefined): string | null {
  if (Array.isArray(value)) {
    return value[0] ?? null;
  }
  return value ?? null;
}

export default async function MostReportedPotholesPage({
  searchParams,
}: {
  searchParams?: Promise<SearchParamRecord>;
} = {}) {
  const resolvedSearchParams = searchParams ? await searchParams : {};
  const limit = Number.parseInt(firstValue(resolvedSearchParams.limit) ?? "20", 10);
  const safeLimit = Number.isInteger(limit) && limit >= 1 && limit <= 100 ? limit : 20;

  const [stats, potholes] = await Promise.all([
    getPublicStats(),
    getTopPotholes(safeLimit),
  ]);

  const rankedRows: PotholeRow[] = (potholes?.potholes ?? [])
    .slice()
    .sort((a, b) => {
      if (b.confirmation_count !== a.confirmation_count) {
        return b.confirmation_count - a.confirmation_count;
      }
      return b.magnitude - a.magnitude;
    });

  return (
    <AppShell
      totalKmMapped="Published report"
      municipalitiesCovered="Province-wide"
      freshness={stats?.generated_at ?? "15-minute cache"}
    >
      <PotholesShell
        limit={safeLimit}
        rows={rankedRows}
        generatedAt={stats?.generated_at ?? null}
      />
    </AppShell>
  );
}
