import Link from "next/link";

import { CONTACT_EMAIL, ODBL_URL, OSM_COPYRIGHT_URL } from "@/lib/site";

const footerLinks: Array<{ href: string; label: string }> = [
  { href: "/methodology", label: "Methodology" },
  { href: "/privacy", label: "Privacy" },
  { href: "/terms", label: "Terms" },
  { href: "/support", label: "Support" },
];

export function SiteFooter() {
  return (
    <footer className="site-footer">
      <nav aria-label="Footer">
        {footerLinks.map((link) => (
          <Link key={link.href} href={link.href}>
            {link.label}
          </Link>
        ))}
        <a href={`mailto:${CONTACT_EMAIL}`}>Contact</a>
      </nav>
      <p>
        Road data{" "}
        <a href={OSM_COPYRIGHT_URL} target="_blank" rel="noopener noreferrer">
          © OpenStreetMap contributors
        </a>{" "}
        · Published under{" "}
        <a href={ODBL_URL} target="_blank" rel="noopener noreferrer">
          ODbL
        </a>
      </p>
    </footer>
  );
}
