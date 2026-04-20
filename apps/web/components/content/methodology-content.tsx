export function MethodologyContent() {
  return (
    <section className="card" style={{ padding: 24, display: "grid", gap: 18 }}>
      <span className="eyebrow">Methodology</span>
      <div className="headline" style={{ fontSize: "clamp(1.9rem, 3vw, 3rem)" }}>
        How RoadSense turns passive driving into a public road-quality map
      </div>
      <div className="lede" style={{ display: "grid", gap: 14 }}>
        <p>
          RoadSense collects accelerometer and location samples while volunteers drive. The server, not the phone,
          matches each accepted reading to a road segment and aggregates those readings into public confidence tiers.
        </p>
        <p>
          Coverage is not the same thing as smoothness. A road can be well-covered and very rough, or sparsely
          covered and still look smooth simply because not enough contributors have driven it yet.
        </p>
        <p>
          Data is refreshed in batches instead of pretending to be live. That keeps the published map stable,
          explainable, and easier to audit.
        </p>
      </div>
    </section>
  );
}
