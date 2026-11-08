import { AppShell } from "@/components/chrome/app-shell";
import { PrivacyContent } from "@/components/content/privacy-content";

// Static on purpose: the App Store privacy-policy URL must load even when the
// API is down, so this page makes no data requests.
export default function PrivacyPage() {
  return (
    <AppShell>
      <PrivacyContent />
    </AppShell>
  );
}
