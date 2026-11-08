"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

import { FeedbackDialog } from "@/components/feedback/feedback-dialog";
import { GetTheAppLinks } from "@/components/chrome/get-the-app-links";
import { FreshnessPill } from "@/components/chrome/freshness-pill";
import type { FreshnessResult } from "@/lib/format";

const links: Array<{ href: string; label: string }> = [
  { href: "/", label: "Map" },
  { href: "/methodology", label: "Methodology" },
  { href: "/privacy", label: "Privacy" },
  { href: "/support", label: "Support" },
];

type TopNavProps = {
  /** Null hides the pill: no claim is better than a wrong one. */
  freshness: FreshnessResult | null;
};

export function TopNav({ freshness }: TopNavProps) {
  const pathname = usePathname();

  return (
    <>
      <a href="#main-content" className="skip-link">
        Skip to content
      </a>
      <header className="top-nav">
        <Link href="/" className="top-nav-brand" aria-label="RoadSense NS home">
          <span className="top-nav-brand-mark" aria-hidden="true">
            <svg
              viewBox="0 0 24 24"
              width="18"
              height="18"
              fill="none"
              stroke="currentColor"
              strokeWidth="2.2"
              strokeLinecap="round"
              strokeLinejoin="round"
            >
              <path d="M4 19 9 5" />
              <path d="M20 19 15 5" />
              <path d="M12 5v3" />
              <path d="M12 11v3" />
              <path d="M12 17v2" />
            </svg>
          </span>
          RoadSense NS
        </Link>

        <nav aria-label="Primary" className="top-nav-links">
          {links.map((link) => (
            <Link
              key={link.href}
              href={link.href}
              className="top-nav-link"
              aria-current={pathname === link.href ? "page" : undefined}
            >
              {link.label}
            </Link>
          ))}
          <FeedbackDialog triggerLabel="Send feedback" triggerClassName="top-nav-link" />
        </nav>

        <div className="top-nav-actions">
          {freshness ? <FreshnessPill label={freshness.label} state={freshness.state} /> : null}
          <GetTheAppLinks className="top-nav-app-links" />
        </div>
      </header>
    </>
  );
}
