import Link from "next/link";

import { AppShell } from "@/components/chrome/app-shell";

export default function NotFound() {
  return (
    <AppShell>
      <section className="content-page">
        <div className="content-card content-card--hero">
          <span className="eyebrow">404</span>
          <h1 className="headline">This road isn&apos;t on the map.</h1>
          <p className="lede">
            The page you&apos;re looking for doesn&apos;t exist, or the link may be out of date. Head back to the
            live map to keep exploring Nova Scotia road quality.
          </p>
          <div style={{ display: "flex", gap: 12, flexWrap: "wrap", marginTop: 8 }}>
            <Link href="/" className="btn btn-primary">
              Back to the map
            </Link>
            <Link href="/methodology" className="btn btn-secondary">
              How RoadSense works
            </Link>
          </div>
        </div>
      </section>
    </AppShell>
  );
}
