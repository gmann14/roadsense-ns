import { AppShell } from "@/components/chrome/app-shell";
import { TermsContent } from "@/components/content/terms-content";

// Static on purpose, like /privacy: it must load even when the API is down.
export default function TermsPage() {
  return (
    <AppShell>
      <TermsContent />
    </AppShell>
  );
}
