import { AppShell } from "@/components/chrome/app-shell";
import { TermsContent } from "@/components/content/terms-content";
import { pageMetadata } from "@/lib/seo";

export const metadata = pageMetadata({
  path: "/terms",
  title: "Terms of use",
  description:
    "Terms for the RoadSense NS apps, website and open data: informational only, never handle your phone while driving, contribution and ODbL data licences, and Nova Scotia law.",
});

// Static on purpose, like /privacy: it must load even when the API is down.
export default function TermsPage() {
  return (
    <AppShell>
      <TermsContent />
    </AppShell>
  );
}
