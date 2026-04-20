import Link from "next/link";

export function TopNav() {
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
          <Link href="/" style={{ fontWeight: 800, fontSize: "1.05rem" }}>
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
          <Link href="/">Map</Link>
          <Link href="/reports/worst-roads">Worst Roads</Link>
          <Link href="/methodology">Methodology</Link>
          <Link href="/privacy">Privacy</Link>
        </nav>
      </header>
    </>
  );
}
