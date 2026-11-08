import { AppShell } from "@/components/chrome/app-shell";
import { PrivacyContent } from "@/components/content/privacy-content";
import { pageMetadata } from "@/lib/seo";

export const metadata = pageMetadata({
  path: "/privacy",
  title: "Privacy policy",
  description:
    "What the RoadSense NS apps and website collect, what they never collect, how private places are removed on your phone, how long data is kept, and how to ask for deletion.",
});

// Static on purpose: the App Store privacy-policy URL must load even when the
// API is down, so this page makes no data requests.
export default function PrivacyPage() {
  return (
    <AppShell>
      <PrivacyContent />
    </AppShell>
  );
}
