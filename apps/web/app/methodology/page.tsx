import { AppShell } from "@/components/chrome/app-shell";
import { MethodologyContent } from "@/components/content/methodology-content";
import { getPublicStats } from "@/lib/api/client";

export default async function MethodologyPage() {
  const stats = await getPublicStats();

  return (
    <AppShell dataUpdatedAt={stats?.data_updated_at ?? null}>
      <MethodologyContent />
    </AppShell>
  );
}
