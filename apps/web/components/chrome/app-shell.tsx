import type { ReactNode } from "react";

import { SiteFooter } from "@/components/chrome/site-footer";
import { TopNav } from "@/components/chrome/top-nav";
import { formatPlainFreshness } from "@/lib/format";

type AppShellProps = {
  children: ReactNode;
  /**
   * Day-rounded timestamp of the last real data change (`data_updated_at`
   * from /stats). When it's missing the freshness pill is hidden rather than
   * guessed.
   */
  dataUpdatedAt?: string | null;
  /**
   * "map" renders the full-bleed map shell: no constrained width, no top
   * padding, and no footer (the map fills the viewport; its attribution
   * control carries the OpenStreetMap/Mapbox credits).
   */
  variant?: "default" | "map";
};

export function AppShell({ children, dataUpdatedAt = null, variant = "default" }: AppShellProps) {
  const freshness = formatPlainFreshness(dataUpdatedAt);

  return (
    <div className={variant === "map" ? "page-shell page-shell--map" : "page-shell"}>
      <TopNav freshness={freshness} />
      <main id="main-content">{children}</main>
      {variant === "map" ? null : <SiteFooter />}
    </div>
  );
}
