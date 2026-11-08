import { AppShell } from "@/components/chrome/app-shell";
import { SupportContent } from "@/components/content/support-content";

// Static on purpose: this is the App Store Support URL and must load even
// when the API is down, so it makes no data requests.
export default function SupportPage() {
  return (
    <AppShell>
      <SupportContent />
    </AppShell>
  );
}
