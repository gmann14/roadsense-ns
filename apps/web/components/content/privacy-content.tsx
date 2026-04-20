export function PrivacyContent() {
  return (
    <section className="card" style={{ padding: 24, display: "grid", gap: 18 }}>
      <span className="eyebrow">Privacy</span>
      <div className="headline" style={{ fontSize: "clamp(1.9rem, 3vw, 3rem)" }}>
        Public map, private contributors
      </div>
      <div className="lede" style={{ display: "grid", gap: 14 }}>
        <p>
          RoadSense filters privacy zones on-device before upload. The public web app is read-only and never exposes
          raw traces, contributor identifiers, or account-level history.
        </p>
        <p>
          The web interface does not use ad trackers or session replay tools. It exists to explain community road
          conditions, not to build behavioral profiles on visitors.
        </p>
        <p>
          Published road-quality and coverage views use aggregated segment-level data only.
        </p>
      </div>
    </section>
  );
}
