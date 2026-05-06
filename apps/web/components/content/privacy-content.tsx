export function PrivacyContent() {
  return (
    <section className="content-page">
      <div className="content-card content-card--hero">
        <span className="eyebrow">Privacy</span>
        <h1 className="content-heading">Public map, private contributors</h1>
        <p className="lede">
          RoadSense exists to publish aggregate road conditions. It is not designed to identify
          individual drivers or show individual trips.
        </p>
        <p className="lede">Last updated: April 24, 2026.</p>
      </div>

      <article id="collect" className="content-card">
        <span className="eyebrow">01 · Collected</span>
        <h2>Road scoring needs motion and location</h2>
        <p className="lede">
          When a contributor opts in, the iPhone can collect accelerometer data, precise location,
          speed, heading, timestamps, and basic crash or performance diagnostics.
        </p>
        <p className="lede">
          The backend also receives normal service metadata, such as IP addresses used for rate
          limiting and abuse prevention. That metadata is not part of the public map.
        </p>
      </article>

      <article id="not-collected" className="content-card">
        <span className="eyebrow">02 · Not collected</span>
        <h2>No account, ads, or profile</h2>
        <p className="lede">
          RoadSense does not ask contributors for a name, email address, phone number, home address,
          or user account.
        </p>
        <p className="lede">The website does not use ad trackers or session replay tools.</p>
      </article>

      <article id="filters" className="content-card">
        <span className="eyebrow">03 · Filters</span>
        <h2>Privacy zones are handled on the phone</h2>
        <p className="lede">
          Samples inside a contributor's privacy zone are discarded before upload. The server does
          not receive those dropped samples or a signal that a privacy zone exists.
        </p>
        <div className="drawer-callout">
          <span className="eyebrow">Public data boundary</span>
          <strong>The public site shows aggregate road segments only.</strong>
          <span className="lede">
            It does not expose raw traces, contributor identifiers, or per-driver history.
          </span>
        </div>
      </article>

      <article id="retention" className="content-card">
        <span className="eyebrow">04 · Retention</span>
        <h2>Raw samples are temporary</h2>
        <p className="lede">
          Contributors can delete local RoadSense data in the app. Server-side raw drive samples are
          kept for up to 6 months, then removed on a rolling basis.
        </p>
        <p className="lede">
          Aggregate road-quality outputs may remain longer because they are community statistics,
          not personal trip histories.
        </p>
      </article>

      <article id="web" className="content-card">
        <span className="eyebrow">05 · Website</span>
        <h2>The public website is read-only</h2>
        <p className="lede">
          The website lets visitors view aggregated road quality, coverage, and pothole markers. It
          does not publish individual drives.
        </p>
        <p className="lede">
          The retired data inventory URL now redirects here so privacy information has one main
          place to live.
        </p>
      </article>

      <article id="contact" className="content-card">
        <span className="eyebrow">06 · Contact</span>
        <h2>Questions and privacy requests</h2>
        <p className="lede">
          For privacy questions, corrections, or concerns about how this policy is being applied,
          contact <a href="mailto:graham.mann14@gmail.com">graham.mann14@gmail.com</a>.
        </p>
        <p className="lede">
          If RoadSense changes what it collects or publishes, this page should be updated before
          broader public testing.
        </p>
      </article>
    </section>
  );
}
