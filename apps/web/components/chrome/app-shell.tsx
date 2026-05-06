import type { ReactNode } from "react";

import { TopNav } from "@/components/chrome/top-nav";
import { TrustStrip } from "@/components/chrome/trust-strip";
import { formatPlainFreshness, type FreshnessState } from "@/lib/format";

type AppShellProps = {
  children: ReactNode;
  totalKmMapped?: string;
  municipalitiesCovered?: string;
  /** ISO timestamp from the public stats payload. Used to derive the freshness pill. */
  freshness?: string | null;
  /** Show the legacy two-metric trust strip below the nav. Off by default — freshness lives in the topbar pill. */
  showTrust?: boolean;
  /** Render the home full-bleed map shell (no constrained page width, no top padding). */
  variant?: "default" | "map";
};

export function AppShell({
  children,
  totalKmMapped = "—",
  municipalitiesCovered = "—",
  freshness = null,
  showTrust = false,
  variant = "default",
}: AppShellProps) {
  const { label, state } = freshnessFor(freshness);

  return (
    <div className={variant === "map" ? "page-shell page-shell--map" : "page-shell"}>
      <TopNav freshnessLabel={label} freshnessState={state} />
      {showTrust ? (
        <TrustStrip
          totalKmMapped={totalKmMapped}
          municipalitiesCovered={municipalitiesCovered}
        />
      ) : null}
      <main id="main-content">{children}</main>
    </div>
  );
}

function freshnessFor(value: string | null | undefined): {
  label: string;
  state: FreshnessState;
} {
  if (!value) {
    return { label: "Awaiting first publish", state: "pending" };
  }
  return formatPlainFreshness(value);
}
