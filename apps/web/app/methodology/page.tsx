import { AppShell } from "@/components/chrome/app-shell";
import { MethodologyContent } from "@/components/content/methodology-content";
import { DatasetJsonLd } from "@/components/seo/dataset-json-ld";
import { getPublicStats } from "@/lib/api/client";
import { pageMetadata } from "@/lib/seo";

export const metadata = pageMetadata({
  path: "/methodology",
  title: "How the map is built",
  description:
    "How RoadSense NS turns phone vibration readings into road-level averages: on-device filters, privacy zones, the 3-contributor floor, confidence tiers, and the ODbL data licence.",
});

export default async function MethodologyPage() {
  const stats = await getPublicStats();

  return (
    <AppShell dataUpdatedAt={stats?.data_updated_at ?? null}>
      <DatasetJsonLd />
      <MethodologyContent />
    </AppShell>
  );
}
