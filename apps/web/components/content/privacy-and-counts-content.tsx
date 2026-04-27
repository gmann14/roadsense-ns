import type { PublicStats } from "@/lib/api/client";

const sections = [
  { id: "live-counts", label: "Live counts" },
  { id: "phone-data", label: "From your phone" },
  { id: "server-data", label: "On the server" },
  { id: "third-parties", label: "Third parties" },
  { id: "controls", label: "Your controls" },
] as const;

type Props = {
  stats: PublicStats | null;
};

const numberFormatter = new Intl.NumberFormat("en-CA");

function formatCount(value: number | null | undefined): string {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return "—";
  }
  return numberFormatter.format(Math.round(value));
}

function formatKilometres(value: number | null | undefined): string {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return "—";
  }
  return `${numberFormatter.format(Math.round(value))} km`;
}

function formatGeneratedAt(value: string | null | undefined): string {
  if (!value) {
    return "—";
  }
  try {
    return new Date(value).toLocaleString("en-CA", {
      dateStyle: "long",
      timeStyle: "short",
      timeZone: "America/Halifax",
    });
  } catch {
    return value;
  }
}

export function PrivacyAndCountsContent({ stats }: Props) {
  return (
    <section style={{ display: "grid", gap: 18 }}>
      <div className="card" style={{ padding: 24, display: "grid", gap: 10 }}>
        <span className="eyebrow">Privacy & counts</span>
        <div className="headline" style={{ fontSize: "clamp(1.9rem, 3vw, 3rem)" }}>
          Every telemetry source, named in plain language
        </div>
        <p className="lede" style={{ margin: 0 }}>
          RoadSense aggregates community road-quality data without tracking individuals. This page lists every place data
          flows, with live counts where they exist. If a source isn&apos;t named here, it isn&apos;t collected.
        </p>
        <nav aria-label="Privacy and counts sections" style={{ display: "flex", flexWrap: "wrap", gap: 8, marginTop: 4 }}>
          {sections.map((section) => (
            <a key={section.id} href={`#${section.id}`} className="secondary-button">
              {section.label}
            </a>
          ))}
        </nav>
      </div>

      <article id="live-counts" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">01 · Live aggregate counts</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>The published map, in numbers</h2>
        <p className="lede" style={{ margin: 0 }}>
          These come straight from the public statistics view that powers the home map. They refresh every few minutes
          and never reference an individual contributor.
        </p>
        <dl
          style={{
            display: "grid",
            gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))",
            gap: 12,
            margin: 0,
          }}
        >
          <CountTile
            label="Kilometres mapped"
            value={formatKilometres(stats?.total_km_mapped)}
            testId="counts.km-mapped"
          />
          <CountTile
            label="Road segments scored"
            value={formatCount(stats?.segments_scored)}
            testId="counts.segments-scored"
          />
          <CountTile
            label="Active potholes"
            value={formatCount(stats?.active_potholes)}
            testId="counts.active-potholes"
          />
          <CountTile
            label="Municipalities covered"
            value={formatCount(stats?.municipalities_covered)}
            testId="counts.municipalities-covered"
          />
          <CountTile
            label="Drive samples published"
            value={formatCount(stats?.total_readings)}
            testId="counts.total-readings"
          />
        </dl>
        <p className="lede" style={{ margin: 0, fontSize: "0.92rem" }}>
          Generated at: <strong data-testid="counts.generated-at">{formatGeneratedAt(stats?.generated_at ?? null)}</strong>
        </p>
      </article>

      <article id="phone-data" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">02 · What leaves your phone</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>Drive samples and pothole reports — that&apos;s it</h2>
        <p className="lede" style={{ margin: 0 }}>
          The iOS app collects accelerometer, location, speed, and heading while you drive. Privacy zones and endpoint
          trimming run on-device, before anything is queued for upload. The app does not have access to your contacts,
          your photo library beyond a single capture you authorise, your advertising ID, or any account on your phone.
        </p>
        <ul style={{ margin: 0, paddingLeft: 20, display: "grid", gap: 6 }}>
          <li>
            <strong>Drive samples</strong> — uploaded as anonymous batches keyed by a rotating device hash. Endpoints
            (start and end of trip) are trimmed before they leave the phone.
          </li>
          <li>
            <strong>Pothole marks and follow-ups</strong> — uploaded with the same anonymous device hash. The server
            never receives your name, email, or any identifier you typed into your phone.
          </li>
          <li>
            <strong>Optional pothole photos</strong> — captured in-app, EXIF-stripped on-device, and only uploaded after
            you tap Submit. Photos go through manual moderation before they touch the public layer.
          </li>
          <li>
            <strong>Feedback you send</strong> — the message you type, the screen you came from, your iOS version, and
            an optional reply email. No location, no drive data, no device ID is attached.
          </li>
        </ul>
      </article>

      <article id="server-data" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">03 · What lives on the server</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>Aggregate views, plus the audit rows behind them</h2>
        <p className="lede" style={{ margin: 0 }}>
          Supabase (PostgreSQL + PostGIS) stores everything below. Raw rows are not exposed publicly — only aggregate
          views that the home map and reports query through.
        </p>
        <ul style={{ margin: 0, paddingLeft: 20, display: "grid", gap: 6 }}>
          <li>
            <strong>readings</strong> — drive samples, retained ~6 months on a rolling basis. Aggregated nightly into
            segment-level scores.
          </li>
          <li>
            <strong>segment_aggregates</strong> — the per-road numbers behind the map. Public.
          </li>
          <li>
            <strong>pothole_reports / pothole_actions / pothole_photos</strong> — manual reports, follow-up confirmations,
            and approved photos. Only active reports and approved photos surface publicly.
          </li>
          <li>
            <strong>feedback_submissions</strong> — feedback messages from this site and the iOS app. Only the
            maintainer (service-role) can read this table; anonymous and signed-in roles cannot.
          </li>
          <li>
            <strong>device_tokens</strong> — anonymous, rotating per-device tokens hashed before storage. Never the raw
            value.
          </li>
          <li>
            <strong>rate_limits</strong> — short-lived counters keyed by IP and device hash, used to throttle abuse.
          </li>
        </ul>
      </article>

      <article id="third-parties" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">04 · Third parties</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>Three named services, scoped tightly</h2>
        <ul style={{ margin: 0, paddingLeft: 20, display: "grid", gap: 6 }}>
          <li>
            <strong>Mapbox</strong> — renders the public map and provides geocoding for the search box. Standard tile
            requests reveal viewport coordinates as you pan, the same as any web map.
          </li>
          <li>
            <strong>Sentry</strong> — captures iOS crashes and slow operations so the app keeps working on real phones.
            User identifiers are never sent. Coordinates and drive data are filtered out before any event leaves the
            phone.
          </li>
          <li>
            <strong>Vercel</strong> — hosts this website. Standard request logs (IP, user agent, path) live in
            Vercel&apos;s infrastructure for operational reliability.
          </li>
        </ul>
        <p className="lede" style={{ margin: 0 }}>
          No analytics, no advertising, no session-replay tools, no Firebase, no Mixpanel, no Amplitude, no PostHog
          cloud, no Segment. If we add another service, it&apos;ll be listed here before it ships.
        </p>
      </article>

      <article id="controls" className="card" style={{ padding: 24, display: "grid", gap: 12 }}>
        <span className="eyebrow">05 · Your controls</span>
        <h2 style={{ margin: 0, fontSize: "1.6rem" }}>Pause, prune, and ask</h2>
        <ul style={{ margin: 0, paddingLeft: 20, display: "grid", gap: 6 }}>
          <li>Pause collection from Settings to stop sending anything new.</li>
          <li>Add a privacy zone to keep an area off the map entirely. Zones are evaluated on-device, before upload.</li>
          <li>Delete local contribution data from Settings. Already published aggregates stay public — they have no link back to your phone.</li>
          <li>Send feedback (top-right of this site, or Settings on iOS) to flag anything you want changed.</li>
          <li>
            Email <a href="mailto:graham.mann14@gmail.com">graham.mann14@gmail.com</a> for anything else, including
            policy challenges or correction requests.
          </li>
        </ul>
      </article>
    </section>
  );
}

function CountTile({ label, value, testId }: { label: string; value: string; testId: string }) {
  return (
    <div
      style={{
        padding: "12px 16px",
        background: "var(--rs-canvas-sunken)",
        borderRadius: "var(--rs-radius-sm)",
        border: "1px solid var(--rs-border)",
        display: "grid",
        gap: 4,
      }}
    >
      <dt
        style={{
          fontSize: "0.7rem",
          letterSpacing: "1.4px",
          fontWeight: 700,
          color: "var(--rs-ink-muted)",
          textTransform: "uppercase",
          margin: 0,
        }}
      >
        {label}
      </dt>
      <dd
        style={{
          margin: 0,
          fontSize: "1.6rem",
          fontWeight: 600,
          fontVariantNumeric: "tabular-nums",
          color: "var(--rs-ink)",
        }}
        data-testid={testId}
      >
        {value}
      </dd>
    </div>
  );
}
