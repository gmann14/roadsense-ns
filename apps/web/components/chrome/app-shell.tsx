import type { ReactNode } from "react";

import { TopNav } from "@/components/chrome/top-nav";
import { TrustStrip } from "@/components/chrome/trust-strip";

type AppShellProps = {
  children: ReactNode;
  totalKmMapped?: string;
  municipalitiesCovered?: string;
  freshness?: string;
  hideTrust?: boolean;
};

export function AppShell({
  children,
  totalKmMapped = "Loading…",
  municipalitiesCovered = "Loading…",
  freshness = "Loading…",
  hideTrust = false,
}: AppShellProps) {
  return (
    <div className="page-shell">
      <TopNav />
      {hideTrust ? null : (
        <TrustStrip
          totalKmMapped={totalKmMapped}
          municipalitiesCovered={municipalitiesCovered}
          freshness={freshness}
        />
      )}
      <main id="main-content">{children}</main>
    </div>
  );
}
