import Link from "next/link";

import {
  MIN_CONTRIBUTORS_HIGH_CONFIDENCE,
  MIN_CONTRIBUTORS_PUBLIC,
  MIN_SPEED_KMH,
  ODBL_URL,
  OSM_COPYRIGHT_URL,
} from "@/lib/site";

const pipelineSteps = [
  {
    tag: "01",
    title: "Phone records",
    body: "Motion and GPS samples while a contributor is driving.",
  },
  {
    tag: "02",
    title: "Phone filters",
    body: "Slow, inaccurate, privacy-zone, and trip start/end samples are dropped before upload.",
  },
  {
    tag: "03",
    title: "Server matches",
    body: "Clean samples are matched to OpenStreetMap road segments.",
  },
  {
    tag: "04",
    title: "Map publishes",
    body: `Road-level averages appear once ${MIN_CONTRIBUTORS_PUBLIC}+ different drivers have covered a road.`,
  },
] as const;

const confidenceTiers = [
  {
    tier: "Low",
    countLabel: `1–${MIN_CONTRIBUTORS_PUBLIC - 1} drivers`,
    blurb: "Not shown on the public map. One or two drivers can't be told apart from a single trip.",
  },
  {
    tier: "Medium",
    countLabel: `${MIN_CONTRIBUTORS_PUBLIC}–${MIN_CONTRIBUTORS_HIGH_CONFIDENCE - 1} drivers`,
    blurb: "Enough different drivers to publish a road-level average and show a pattern.",
  },
  {
    tier: "High",
    countLabel: `${MIN_CONTRIBUTORS_HIGH_CONFIDENCE}+ drivers`,
    blurb: "Many different drivers agree. This is the most stable public tier.",
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
          Road scoring doesn&apos;t use the microphone or camera. Contributing doesn&apos;t need a name,
          email address, or user account.
        </p>
        <CollectionDiagram />
      </article>

      <article id="filters" className="content-card">
        <span className="eyebrow">02 · Filters</span>
        <h2>The phone drops data that should not be uploaded</h2>
        <p className="lede">
          Samples below {MIN_SPEED_KMH} km/h (or implausibly fast), samples with poor GPS accuracy, and
          samples inside a contributor&apos;s privacy zones are removed on the phone. The phone also trims
          the start and end of every drive: the first and last minute, and anything within 300 m of
          where the drive started or ended. None of that filtered data is sent to the server.
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
          <strong>
            Only road-level results, and only once at least {MIN_CONTRIBUTORS_PUBLIC} different drivers have
            covered a road.
          </strong>
          <span className="lede">
            Individual traces and contributor histories are never exposed. Public dates are rounded to the
            day, so the map can&apos;t be used to time someone&apos;s trip. New pothole markers appear only
            after at least two different devices report the same spot.
          </span>
        </div>
      </article>

      <article id="confidence" className="content-card">
        <span className="eyebrow">04 · Confidence</span>
        <h2>Confidence depends on how many different drivers covered a road</h2>
        <p className="lede">
          Confidence counts different contributors, not trips. Contributors are counted by an anonymous
          device token that rotates about every 30 days, so one person driving the same road for several
          months can count more than once. A smooth-looking road at medium confidence is still an early
          signal.
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
              <strong>Not a maintenance queue.</strong> The map does not decide repair priority, and no
              municipality or province endorses it.
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
              <strong>Not complete coverage.</strong> A road with no colour usually means fewer than{" "}
              {MIN_CONTRIBUTORS_PUBLIC} drivers have covered it so far, not that it&apos;s smooth.
            </span>
          </li>
        </ul>
      </article>

      <article id="data-licence" className="content-card">
        <span className="eyebrow">06 · Data licence</span>
        <h2>Open data, with attribution</h2>
        <p className="lede">
          Road geometry comes from{" "}
          <a href={OSM_COPYRIGHT_URL} target="_blank" rel="noopener noreferrer">
            © OpenStreetMap contributors
          </a>
          . Because the published road scores are built on OpenStreetMap data, the aggregated RoadSense
          data is made available under the{" "}
          <a href={ODBL_URL} target="_blank" rel="noopener noreferrer">
            Open Database License (ODbL) 1.0
          </a>
          . Base map tiles are © Mapbox and © OpenStreetMap contributors.
        </p>
        <p className="lede">
          Data: <a href={ODBL_URL} target="_blank" rel="noopener noreferrer">ODbL</a> · See the{" "}
          <Link href="/terms">terms of use</Link> for how contributions are licensed.
        </p>
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
  // Bars are a log-ish visual of the thresholds (1, 3, 10), not of real counts.
  const widths: Record<(typeof confidenceTiers)[number]["tier"], number> = { Low: 18, Medium: 50, High: 100 };
  return (
    <div className="confidence-grid" aria-label="Confidence tier comparison">
      {confidenceTiers.map((tier) => (
        <div key={tier.tier} className={`confidence-tier tier-${tier.tier.toLowerCase()}`}>
          <div className="confidence-tier-head">
            <span className="confidence-tier-label">{tier.tier} confidence</span>
            <span className="confidence-tier-count">
              {tier.countLabel}
            </span>
          </div>
          <div className="confidence-bar">
            <div className="confidence-fill" style={{ width: `${widths[tier.tier]}%` }} />
          </div>
          <p className="confidence-blurb">{tier.blurb}</p>
        </div>
      ))}
    </div>
  );
}
