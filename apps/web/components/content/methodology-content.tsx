const pipelineSteps = [
  {
    tag: "01",
    title: "Phone records",
    body: "Motion and GPS samples while a contributor is driving.",
  },
  {
    tag: "02",
    title: "Phone filters",
    body: "Stopped, slow, or private-zone samples are dropped before upload.",
  },
  {
    tag: "03",
    title: "Server matches",
    body: "Clean samples are matched to OpenStreetMap road segments.",
  },
  {
    tag: "04",
    title: "Map publishes",
    body: "The public map shows road-level aggregates, not individual drives.",
  },
] as const;

const confidenceTiers = [
  {
    tier: "Low",
    drivers: 6,
    blurb: "Early signal. Useful for orientation, not for conclusions.",
  },
  {
    tier: "Medium",
    drivers: 22,
    blurb: "Enough repeat coverage to show a pattern.",
  },
  {
    tier: "High",
    drivers: 78,
    blurb: "Many drives agree. This is the most stable public tier.",
  },
] as const;

export function MethodologyContent() {
  return (
    <section className="content-page">
      <div className="content-card content-card--hero">
        <span className="eyebrow">Methodology</span>
        <h1 className="content-heading">How RoadSense builds the public map</h1>
        <p className="lede">
          RoadSense turns phone motion and GPS samples into road-level averages. This page explains
          what is collected, what is filtered out, and how confidence is assigned.
        </p>
      </div>

      <article id="collection" className="content-card">
        <span className="eyebrow">01 · Collection</span>
        <h2>The app records only the signals needed to score roads</h2>
        <p className="lede">
          Contributors opt into passive collection while driving. The app samples vehicle motion,
          location, speed, heading, and time so the backend can connect roughness to the right road.
        </p>
        <p className="lede">
          RoadSense does not use the microphone or camera. It does not need a name, email address,
          or user account to contribute road-quality data.
        </p>
        <CollectionDiagram />
      </article>

      <article id="filters" className="content-card">
        <span className="eyebrow">02 · Filters</span>
        <h2>The phone drops data that should not be uploaded</h2>
        <p className="lede">
          Samples below 25 km/h, idle time, and samples inside a contributor's privacy zone are
          removed on-device. That filtered data is not sent to the server.
        </p>
        <p className="lede">
          This is also why the public map can lag behind a drive. We prefer slower, cleaner
          aggregates over a map that publishes every possible bump immediately.
        </p>
      </article>

      <article id="aggregation" className="content-card">
        <span className="eyebrow">03 · Aggregation</span>
        <h2>The server matches clean samples to roads</h2>
        <p className="lede">
          The backend snaps uploaded samples to OpenStreetMap road segments, then combines repeat
          passes from different drives. The public map is built from those segment aggregates.
        </p>
        <div className="drawer-callout">
          <span className="eyebrow">What gets published</span>
          <strong>Only segment-level results appear on the public site.</strong>
          <span className="lede">
            Individual traces and contributor histories are not exposed through the map. New
            pothole markers appear only after at least two different devices report the same spot.
          </span>
        </div>
      </article>

      <article id="confidence" className="content-card">
        <span className="eyebrow">04 · Confidence</span>
        <h2>Confidence depends on repeat coverage</h2>
        <p className="lede">
          A smooth-looking road with low confidence is still only an early signal. As more drives
          cover the same segment, the score becomes more stable.
        </p>
        <ConfidenceDiagram />
      </article>

      <article id="limits" className="content-card">
        <span className="eyebrow">05 · Limits</span>
        <h2>What the map does not mean</h2>
        <ul className="method-not-list">
          <li>
            <span className="x" aria-hidden="true">x</span>
            <span>
              <strong>Not a maintenance queue.</strong> The map does not decide repair priority.
            </span>
          </li>
          <li>
            <span className="x" aria-hidden="true">x</span>
            <span>
              <strong>Not emergency reporting.</strong> Dangerous road conditions should still go
              to the right public works or emergency contact.
            </span>
          </li>
          <li>
            <span className="x" aria-hidden="true">x</span>
            <span>
              <strong>Not surveillance.</strong> The public site does not publish individual driver
              traces.
            </span>
          </li>
          <li>
            <span className="x" aria-hidden="true">x</span>
            <span>
              <strong>Not complete coverage.</strong> Grey roads usually mean RoadSense does not
              have enough data yet.
            </span>
          </li>
        </ul>
      </article>
    </section>
  );
}

function CollectionDiagram() {
  return (
    <ol className="pipeline" aria-label="Collection pipeline">
      {pipelineSteps.map((step, index) => (
        <li key={step.tag} className="pipeline-step">
          <div className="pipeline-tag">{step.tag}</div>
          <div className="pipeline-body">
            <strong>{step.title}</strong>
            <p>{step.body}</p>
          </div>
          {index < pipelineSteps.length - 1 ? (
            <div className="pipeline-arrow" aria-hidden="true">-&gt;</div>
          ) : null}
        </li>
      ))}
    </ol>
  );
}

function ConfidenceDiagram() {
  const max = Math.max(...confidenceTiers.map((tier) => tier.drivers));
  return (
    <div className="confidence-grid" aria-label="Confidence tier comparison">
      {confidenceTiers.map((tier) => (
        <div key={tier.tier} className={`confidence-tier tier-${tier.tier.toLowerCase()}`}>
          <div className="confidence-tier-head">
            <span className="confidence-tier-label">{tier.tier} confidence</span>
            <span className="confidence-tier-count">
              {tier.drivers}
              <span> drives</span>
            </span>
          </div>
          <div className="confidence-bar">
            <div
              className="confidence-fill"
              style={{ width: `${(tier.drivers / max) * 100}%` }}
            />
          </div>
          <p className="confidence-blurb">{tier.blurb}</p>
        </div>
      ))}
    </div>
  );
}
