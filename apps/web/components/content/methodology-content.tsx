const tocSections = [
  { id: "collection", label: "01 · Collection" },
  { id: "aggregation", label: "02 · Aggregation" },
  { id: "confidence", label: "03 · Confidence" },
  { id: "cadence", label: "04 · Refresh" },
  { id: "limits", label: "05 · What it isn't" },
] as const;

const pipelineSteps = [
  {
    tag: "01",
    title: "Phone records",
    body: "Accelerometer + GPS samples while driving. No mic, no camera.",
  },
  {
    tag: "02",
    title: "Phone filters",
    body: "Anything below 25 km/h, idle, or inside a privacy zone is dropped on-device.",
  },
  {
    tag: "03",
    title: "Server matches",
    body: "Clean traces are snapped to a road segment in OpenStreetMap.",
  },
  {
    tag: "04",
    title: "Public aggregate",
    body: "Per-segment averages refresh nightly. No individual trace is ever published.",
  },
] as const;

const confidenceTiers = [
  {
    tier: "Low",
    drivers: 6,
    blurb: "A hint, not a claim. Treat the colour as provisional.",
  },
  {
    tier: "Medium",
    drivers: 22,
    blurb: "Pattern is real but the pill might shift as more data lands.",
  },
  {
    tier: "High",
    drivers: 78,
    blurb: "Stable enough to cite. Many drivers, many trips, agreement.",
  },
] as const;

export function MethodologyContent() {
  return (
    <div className="methodology">
      <header className="methodology-hero">
        <span className="eyebrow">How we know what we know</span>
        <h1 className="text-balance">
          Every line on the map is a real drive on a real road. Here's how we get from one to the other.
        </h1>
        <p className="lede">
          You don't have to take our word for it. This page is the audit trail — for residents who
          want to know if they can trust the green pill on their street, and for journalists who
          want to know what they can responsibly cite.
        </p>
        <nav className="method-toc" aria-label="Sections">
          {tocSections.map((section) => (
            <a key={section.id} href={`#${section.id}`}>
              {section.label}
            </a>
          ))}
        </nav>
      </header>

      <section id="collection" className="method-section">
        <div className="num">01</div>
        <div>
          <h2>Phones do the listening, not the thinking.</h2>
          <p>
            Volunteer drivers opt into a passive mode in the RoadSense app. While they drive,
            their phone samples two things: how the car is shaking (accelerometer) and where it is
            (GPS). That's it — no microphone, no camera, no continuous tracking when stopped.
          </p>
          <p>
            <strong>Anything that fails an on-device privacy filter never leaves the phone.</strong>{" "}
            Speeds below 25 km/h, idle moments at intersections, and any trace inside a user-set
            privacy zone (your home, your kid's school) are dropped before the upload step.
          </p>
          <CollectionDiagram />
        </div>
      </section>

      <section id="aggregation" className="method-section">
        <div className="num">02</div>
        <div>
          <h2>The map is built on the server, not on your phone.</h2>
          <p>
            When a phone uploads a clean trace, the server, not the phone, matches each drive sample
            to a road and turns repeated passes into public confidence tiers. It snaps the reading to
            a specific segment in OpenStreetMap, then averages it together with every other driver's
            readings on that same segment.
          </p>
          <p>
            Doing this server-side is a deliberate choice. It means the math is consistent across
            app versions, and we can correct mismatches without shipping a mobile update.
          </p>
          <div className="callout">
            <span className="eyebrow">Why this matters</span>
            <p>
              <strong>Your phone never decides what your street looks like to the public.</strong>{" "}
              That decision is made by the average of many drivers on a shared map.
            </p>
          </div>
        </div>
      </section>

      <section id="confidence" className="method-section">
        <div className="num">03</div>
        <div>
          <h2>A green road isn't a promise. It's a confidence level.</h2>
          <p>
            Coverage is not the same as smoothness. A road can be well-driven and very rough; or
            sparsely driven and look smooth simply because not enough people have been on it yet.
          </p>
          <p>
            That's why every published road carries a confidence tier. <strong>A "smooth" pill at
            low confidence is a hint. The same pill at high confidence is a claim.</strong>
          </p>
          <ConfidenceDiagram />
        </div>
      </section>

      <section id="cadence" className="method-section">
        <div className="num">04</div>
        <div>
          <h2>Stable beats real-time.</h2>
          <p>
            Data is refreshed in batches instead of pretending to be live. <strong>Aggregates
            recompute nightly. Tile caches refresh every fifteen minutes.</strong> A pothole reported
            at 2 PM today shows up on the public map tomorrow morning, after enough other drivers
            have hit it to confirm it's not a bag of mulch.
          </p>
          <p>
            That delay is the price of a map that's worth trusting. We'd rather be a day late than
            a confident map of false positives.
          </p>
        </div>
      </section>

      <section id="limits" className="method-section">
        <div className="num">05</div>
        <div>
          <h2>What this isn't.</h2>
          <p>
            RoadSense is community observation. It's a way for people who use roads to describe
            their condition, in numbers, in public. To be clear about what it is <em>not</em>:
          </p>
          <ul className="method-not-list">
            <li>
              <span className="x" aria-hidden="true">×</span>
              <span>
                <strong>Not a maintenance queue.</strong> A pothole on this map isn't a contract of
                repair. Municipalities pick their own priorities.
              </span>
            </li>
            <li>
              <span className="x" aria-hidden="true">×</span>
              <span>
                <strong>Not a 911 substitute.</strong> If a road is dangerous right now, call your
                local public works line.
              </span>
            </li>
            <li>
              <span className="x" aria-hidden="true">×</span>
              <span>
                <strong>Not surveillance.</strong> Individual driver traces are never published.
                Only the aggregate per road segment leaves our servers.
              </span>
            </li>
            <li>
              <span className="x" aria-hidden="true">×</span>
              <span>
                <strong>Not a complete map.</strong> Roads with no driver coverage stay grey. Grey
                does not mean smooth.
              </span>
            </li>
          </ul>
        </div>
      </section>
    </div>
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
            <div className="pipeline-arrow" aria-hidden="true">→</div>
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
              <span> drivers</span>
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
