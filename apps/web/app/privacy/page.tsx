import { AppShell } from "@/components/chrome/app-shell";
import { PrivacyContent } from "@/components/content/privacy-content";

export default function PrivacyPage() {
  return (
    <AppShell
      totalKmMapped="Privacy"
      municipalitiesCovered="Read-only public web"
      freshness="Static content"
    >
      <PrivacyContent />
    </AppShell>
  );
}
