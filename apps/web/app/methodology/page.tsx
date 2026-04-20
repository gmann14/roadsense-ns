import { AppShell } from "@/components/chrome/app-shell";
import { MethodologyContent } from "@/components/content/methodology-content";

export default function MethodologyPage() {
  return (
    <AppShell
      totalKmMapped="Methodology"
      municipalitiesCovered="Public explanation"
      freshness="Static content"
    >
      <MethodologyContent />
    </AppShell>
  );
}
