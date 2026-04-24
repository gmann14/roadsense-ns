const sections = [
  { id: "collect", label: "What we collect" },
  { id: "dont-collect", label: "What we don't" },
  { id: "on-device", label: "On-device filters" },
  { id: "retention", label: "Retention" },
  { id: "web", label: "Web experience" },
  { id: "contact", label: "Contact" },
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
          RoadSense exists to publish a community road-quality map, not to build profiles of individual drivers. This
          page explains what the app collects, what it does not collect, how long data is kept, and what controls
          contributors have before anything reaches the public map.
        </p>
        <p className="lede" style={{ margin: 0 }}>
          Last updated: April 24, 2026.
        </p>
        <nav aria-label="Privacy sections" style={{ display: "flex", flexWrap: "wrap", gap: 8, marginTop: 4 }}>
          {sections.map((section) => (
            <a key={section.id} href={`#${section.id}`} className="secondary-button">
              {section.label}
            </a>
          ))}
        </nav>
      </div>

      <article id="collect" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">01 · What we collect</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>Only the signals needed to score roads</h2>
        <p className="lede" style={{ margin: 0 }}>
          When a contributor opts in, the iPhone can collect accelerometer data, precise location, speed, headings,
          timestamps, and limited crash/performance diagnostics. The backend also sees network metadata needed to
          operate the service, such as IP addresses for rate limiting, but those fields are not part of the public map.
        </p>
        <div className="drawer-callout">
          <span className="eyebrow">Why this data exists</span>
          <strong>We use motion plus location to match roughness readings to road segments.</strong>
          <span className="lede">
            Without those two signal types together, the service cannot tell whether a bump happened on Barrington
            Street, Robie Street, or in a driveway that should never be published.
          </span>
        </div>
      </article>

      <article id="dont-collect" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">02 · What we don&apos;t collect</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>No account, no ads, no personal profile</h2>
        <p className="lede" style={{ margin: 0 }}>
          RoadSense does not ask for your name, email, phone number, home address, or a user account to contribute
          road-quality data. It does not use advertising IDs, ad trackers, or session replay tools.
        </p>
        <p className="lede" style={{ margin: 0 }}>
          The public web app is read-only. It does not expose raw traces, contributor identifiers, or per-driver
          history.
        </p>
      </article>

      <article id="on-device" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">03 · On-device filters</span>
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

      <article id="retention" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">04 · Retention and deletion</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>Short-lived raw data, longer-lived aggregates</h2>
        <p className="lede" style={{ margin: 0 }}>
          Contributors can delete all local data from inside the app at any time. On the server, raw readings are kept
          for up to 6 months and then deleted on a rolling basis. Aggregate road-quality outputs may remain longer
          because they are published community statistics rather than personal trip histories.
        </p>
        <p className="lede" style={{ margin: 0 }}>
          Because RoadSense does not use accounts, some server-side data cannot be tied back to a known person in the
          way a typical consumer app can. That is a deliberate privacy choice, not an excuse to be vague about
          retention.
        </p>
      </article>

      <article id="web" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">05 · Web experience</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>No trackers, no session replay</h2>
        <p className="lede" style={{ margin: 0 }}>
          The web interface does not use ad trackers or session replay tools. It exists to explain community road
          conditions, not to build behavioral profiles on visitors.
        </p>
        <p className="lede" style={{ margin: 0 }}>
          Published road-quality and coverage views use aggregated segment-level data only. Individual drives cannot
          be isolated from the public surface; per-contributor activity stays server-side and is used only to
          recompute the aggregates you see here.
        </p>
      </article>

      <article id="contact" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">06 · Contact and requests</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>Questions, corrections, and privacy requests</h2>
        <p className="lede" style={{ margin: 0 }}>
          Contributors can wipe their local contribution data from inside the app at any time. If you have a privacy
          question, a correction request, or want to challenge how this policy is being applied, contact{" "}
          <a href="mailto:graham.mann14@gmail.com">graham.mann14@gmail.com</a>.
        </p>
        <p className="lede" style={{ margin: 0 }}>
          We will answer in plain language. If the implementation changes in a way that affects what data is collected
          or published, this page will be updated before broader public testing.
        </p>
      </article>
    </section>
  );
}
