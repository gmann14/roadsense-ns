import type { PotholeRow, PublicStats } from "@/lib/api/client";
import type { MunicipalityConfig } from "@/lib/municipality-manifest";
import type { SearchParamRecord } from "@/lib/url-state";

import { MapExplorer } from "./map-explorer";

type MapShellProps = {
  municipality?: MunicipalityConfig | null;
  searchParams?: SearchParamRecord;
  stats: PublicStats | null;
  topPotholes?: PotholeRow[];
};

export function MapShell({ municipality, searchParams, stats, topPotholes = [] }: MapShellProps) {
  return (
    <MapExplorer
      municipality={municipality}
      searchParams={searchParams}
      stats={stats}
      topPotholes={topPotholes}
    />
  );
}
