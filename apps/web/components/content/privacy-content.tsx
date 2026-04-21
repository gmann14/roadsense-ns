const sections = [
  { id: "on-device", label: "On-device filters" },
  { id: "web", label: "Web experience" },
  { id: "aggregates", label: "Aggregates only" },
  { id: "requests", label: "Your requests" },
] as const;

export function PrivacyContent() {
  return (
    <section style={{ display: "grid", gap: 18 }}>
      <div className="card" style={{ padding: 24, display: "grid", gap: 10 }}>
        <span className="eyebrow">Privacy</span>
        <div className="headline" style={{ fontSize: "clamp(1.9rem, 3vw, 3rem)" }}>
          Public map, private contributors
        </div>
        <p className="lede" style={{ margin: 0 }}>
          Road quality improves when neighbours share passively what their cars already feel. That only works if
          contributing is genuinely private by default &mdash; and if the public surface can&rsquo;t be reverse-engineered
          into someone&rsquo;s routine.
        </p>
        <nav aria-label="Privacy sections" style={{ display: "flex", flexWrap: "wrap", gap: 8, marginTop: 4 }}>
          {sections.map((section) => (
            <a key={section.id} href={`#${section.id}`} className="secondary-button">
              {section.label}
            </a>
          ))}
        </nav>
      </div>

      <article id="on-device" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">01 · On-device filters</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>Your home never leaves your phone</h2>
        <p className="lede" style={{ margin: 0 }}>
          RoadSense filters privacy zones on-device before upload. The public web app is read-only and never exposes
          raw traces, contributor identifiers, or account-level history.
        </p>
        <div className="drawer-callout">
          <span className="eyebrow">Built in, not bolted on</span>
          <strong>Zones are evaluated locally in the app.</strong>
          <span className="lede">
            Readings inside a zone are discarded before the upload queue is even touched. The server never receives a
            signal that a zone exists near you.
          </span>
        </div>
      </article>

      <article id="web" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">02 · Web experience</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>No trackers, no session replay</h2>
        <p className="lede" style={{ margin: 0 }}>
          The web interface does not use ad trackers or session replay tools. It exists to explain community road
          conditions, not to build behavioral profiles on visitors.
        </p>
      </article>

      <article id="aggregates" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">03 · Aggregates only</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>Everything public is already aggregated</h2>
        <p className="lede" style={{ margin: 0 }}>
          Published road-quality and coverage views use aggregated segment-level data only. Individual drives cannot
          be isolated from the public surface; per-contributor activity stays server-side and is used only to
          recompute the aggregates you see here.
        </p>
      </article>

      <article id="requests" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">04 · Your requests</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>Deletion on request</h2>
        <p className="lede" style={{ margin: 0 }}>
          Contributors can wipe their local contribution data from inside the app at any time. For full account
          deletion or data portability requests, reach out through the contact path listed in the app &mdash; we will act
          on it on a known cadence and confirm when it is done.
        </p>
      </article>
    </section>
  );
}
