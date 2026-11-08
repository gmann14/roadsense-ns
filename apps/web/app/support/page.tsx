import { AppShell } from "@/components/chrome/app-shell";
import { SupportContent } from "@/components/content/support-content";
import { pageMetadata } from "@/lib/seo";

export const metadata = pageMetadata({
  path: "/support",
  title: "Support",
  description:
    "Help for the RoadSense NS app: battery use, privacy zones, why roads aren't on the map yet, deleting your data, iPhone and Android availability, and how to contact us.",
});

// Static on purpose: this is the App Store Support URL and must load even
// when the API is down, so it makes no data requests.
export default function SupportPage() {
  return (
    <AppShell>
      <SupportContent />
    </AppShell>
  );
}
