import type { ReactNode } from "react";

import { TopNav } from "@/components/chrome/top-nav";
import { TrustStrip } from "@/components/chrome/trust-strip";

type AppShellProps = {
  children: ReactNode;
  totalKmMapped?: string;
  municipalitiesCovered?: string;
  freshness?: string;
};

export function AppShell({
  children,
  totalKmMapped = "Loading…",
  municipalitiesCovered = "Loading…",
  freshness = "Loading…",
}: AppShellProps) {
  return (
    <div className="page-shell">
      <TopNav />
      <TrustStrip
        totalKmMapped={totalKmMapped}
        municipalitiesCovered={municipalitiesCovered}
        freshness={freshness}
      />
      {children}
    </div>
  );
}
