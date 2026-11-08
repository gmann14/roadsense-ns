import type { ApiResult, PotholeResponse, PublicStats } from "@/lib/api/client";
import type { MunicipalityConfig } from "@/lib/municipality-manifest";
import type { SearchParamRecord } from "@/lib/url-state";

import { MapExplorer } from "./map-explorer";

type MapShellProps = {
  municipality?: MunicipalityConfig | null;
  searchParams?: SearchParamRecord;
  stats: PublicStats | null;
  /** Server-loaded top potholes; null when the page didn't need them. */
  initialTopPotholes?: ApiResult<PotholeResponse> | null;
};

export function MapShell({ municipality, searchParams, stats, initialTopPotholes = null }: MapShellProps) {
  return (
    <MapExplorer
      municipality={municipality}
      searchParams={searchParams}
      stats={stats}
      initialTopPotholes={initialTopPotholes}
    />
  );
}
