import { AppShell } from "@/components/chrome/app-shell";
import { PrivacyContent } from "@/components/content/privacy-content";
import { getPublicStats } from "@/lib/api/client";

export default async function PrivacyPage() {
  const stats = await getPublicStats();

  return (
    <AppShell freshness={stats?.generated_at ?? null}>
      <PrivacyContent />
    </AppShell>
  );
}
