import { AppShell } from "@/components/chrome/app-shell";
import { PrivacyAndCountsContent } from "@/components/content/privacy-and-counts-content";
import { getPublicStats } from "@/lib/api/client";

export const revalidate = 300;

export const metadata = {
  title: "Privacy & counts — RoadSense NS",
  description:
    "Every telemetry source RoadSense NS uses, named in plain language, with live aggregate counts.",
};

export default async function PrivacyAndCountsPage() {
  const stats = await getPublicStats();

  return (
    <AppShell
      totalKmMapped="Privacy & counts"
      municipalitiesCovered="Telemetry transparency"
      freshness="Live aggregates"
    >
      <PrivacyAndCountsContent stats={stats} />
    </AppShell>
  );
}
