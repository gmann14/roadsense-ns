const sections = [
  { id: "collection", label: "Collection" },
  { id: "aggregation", label: "Aggregation" },
  { id: "confidence", label: "Confidence" },
  { id: "cadence", label: "Refresh cadence" },
  { id: "limits", label: "What this is not" },
] as const;

export function MethodologyContent() {
  return (
    <section style={{ display: "grid", gap: 18 }}>
      <div className="card" style={{ padding: 24, display: "grid", gap: 10 }}>
        <span className="eyebrow">Methodology</span>
        <div className="headline" style={{ fontSize: "clamp(1.9rem, 3vw, 3rem)" }}>
          How RoadSense turns passive driving into a public road-quality map
        </div>
        <p className="lede" style={{ margin: 0 }}>
          Every published pixel on this map ties back to a real drive, a specific road segment, and a recompute
          cadence that is open about its limits. This page exists so journalists, residents, and municipal staff can
          audit the pipeline without talking to us first.
        </p>
        <nav aria-label="Methodology sections" style={{ display: "flex", flexWrap: "wrap", gap: 8, marginTop: 4 }}>
          {sections.map((section) => (
            <a key={section.id} href={`#${section.id}`} className="secondary-button">
              {section.label}
            </a>
          ))}
        </nav>
      </div>

      <article id="collection" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">01 · Collection</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>What the phone actually sees</h2>
        <p className="lede" style={{ margin: 0 }}>
          Contributors opt in to a passive-collection mode that samples accelerometer and GPS at cruising speed, then
          applies on-device filters (speed, stationary detection, privacy zones) before anything is uploaded. Traces
          inside a privacy zone never leave the device.
        </p>
      </article>

      <article id="aggregation" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">02 · Aggregation</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>Server-side road matching</h2>
        <p className="lede" style={{ margin: 0 }}>
          RoadSense collects accelerometer and location samples while volunteers drive. The server, not the phone,
          matches each accepted reading to a road segment and aggregates those readings into public confidence tiers.
        </p>
        <div className="drawer-callout">
          <span className="eyebrow">Why server-side</span>
          <strong>Clients never touch the authoritative road network.</strong>
          <span className="lede">
            Moving the match server-side keeps the per-segment math consistent across app versions, and makes it easy
            for us to correct mismatches without shipping a mobile release.
          </span>
        </div>
      </article>

      <article id="confidence" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">03 · Confidence</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>Coverage is not the same thing as smoothness</h2>
        <p className="lede" style={{ margin: 0 }}>
          Coverage is not the same thing as smoothness. A road can be well-covered and very rough, or sparsely
          covered and still look smooth simply because not enough contributors have driven it yet.
        </p>
        <p className="lede" style={{ margin: 0 }}>
          That is why every published road carries a confidence tier. A green &ldquo;smooth&rdquo; pill at low
          confidence is a hint; the same pill at high confidence is a claim.
        </p>
      </article>

      <article id="cadence" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">04 · Refresh cadence</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>Stable over real-time</h2>
        <p className="lede" style={{ margin: 0 }}>
          Data is refreshed in batches instead of pretending to be live. That keeps the published map stable,
          explainable, and easier to audit. Aggregates recompute nightly; tile caches refresh every fifteen minutes.
        </p>
      </article>

      <article id="limits" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">05 · What this is not</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>Not a maintenance queue</h2>
        <p className="lede" style={{ margin: 0 }}>
          Nothing here is a work order. RoadSense is a community observation platform, not a municipal backlog.
          Potholes on the map reflect driver-confirmed impacts, not a contract of repair.
        </p>
      </article>
    </section>
  );
}
