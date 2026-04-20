"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

export function TopNav() {
  const pathname = usePathname();

  return (
    <>
      <a href="#main-content" className="skip-link">
        Skip to content
      </a>
      <header
        className="card"
        style={{
          display: "flex",
          alignItems: "center",
          flexWrap: "wrap",
          justifyContent: "space-between",
          padding: "14px 18px",
          marginBottom: 18,
        }}
      >
        <div style={{ display: "grid", gap: 2 }}>
          <span className="eyebrow">Nova Scotia road quality</span>
          <Link href="/" className="top-nav-brand">
            RoadSense NS
          </Link>
        </div>

        <nav
          aria-label="Primary"
          style={{
            display: "flex",
            flexWrap: "wrap",
            gap: 14,
            color: "var(--rs-text-muted)",
            fontSize: "0.95rem",
          }}
        >
          <Link href="/" className="top-nav-link" aria-current={pathname === "/" ? "page" : undefined}>
            Map
          </Link>
          <Link
            href="/reports/worst-roads"
            className="top-nav-link"
            aria-current={pathname === "/reports/worst-roads" ? "page" : undefined}
          >
            Worst Roads
          </Link>
          <Link href="/methodology" className="top-nav-link" aria-current={pathname === "/methodology" ? "page" : undefined}>
            Methodology
          </Link>
          <Link href="/privacy" className="top-nav-link" aria-current={pathname === "/privacy" ? "page" : undefined}>
            Privacy
          </Link>
        </nav>
      </header>
    </>
  );
}
