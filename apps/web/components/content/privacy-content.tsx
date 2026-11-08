import Link from "next/link";

import {
  CONTACT_EMAIL,
  MIN_CONTRIBUTORS_PUBLIC,
  ODBL_URL,
  POLICY_EFFECTIVE_DATE,
} from "@/lib/site";

const retentionRows: Array<{ data: string; kept: string }> = [
  {
    data: "Road readings (location, time, roughness)",
    kept: "Deleted about 6–7 months after collection. Readings are stored in monthly batches, and a whole month is deleted once all of it is more than 6 months old.",
  },
  {
    data: "Readings that couldn't be matched to a road yet",
    kept: "Held so they can be matched once road data improves. Automatic deletion after 90 days is being added; until it's running, they may be kept longer.",
  },
  {
    data: "Pothole reports and confirmations",
    kept: "The report record is kept while the pothole is active. Public pothole markers expire if nobody confirms them again.",
  },
  {
    data: "Device token",
    kept: "Your phone replaces it about every 30 days. We only store a one-way hash, and it is deleted along with the readings it came with.",
  },
  {
    data: "Feedback messages and reply emails",
    kept: "Kept while we deal with the report. We delete feedback, including any email address, on request.",
  },
  {
    data: "IP addresses",
    kept: "Used for rate limiting and abuse prevention. Some records that include an IP address (feedback and rate-limit records) aren't deleted automatically yet. We're adding automatic deletion, and until then we delete them on request.",
  },
  {
    data: "Crash and error reports",
    kept: "Deleted automatically by Sentry after its retention period (up to 90 days).",
  },
  {
    data: "Road-level averages and published pothole markers",
    kept: "Kept as long as they're useful. They're community statistics, not personal trip histories.",
  },
  {
    data: "Data on your phone",
    kept: "Stays on your phone until you delete it in the app or uninstall the app.",
  },
];

const processors: Array<{ name: string; role: string; location: string }> = [
  { name: "Railway", role: "Hosts our API and database, where uploaded readings are stored.", location: "United States" },
  {
    name: "Cloudflare",
    role: "Hosts this website and sits in front of our API. It sees IP addresses and request details.",
    location: "Global network; United States company",
  },
  {
    name: "Mapbox",
    role: "Draws the maps in the apps and on this website, and runs the website's place search. It receives the map areas you view and your IP address, and its map software can send Mapbox usage data.",
    location: "United States",
  },
  { name: "Sentry", role: "Receives crash and error reports from the apps.", location: "United States" },
  {
    name: "Apple and Google",
    role: "Distribute the apps and provide the operating-system permissions they use.",
    location: "United States",
  },
];

export function PrivacyContent() {
  return (
    <section className="content-page">
      <div className="content-card content-card--hero">
        <span className="eyebrow">Privacy policy</span>
        <h1 className="content-heading">Public map, private contributors</h1>
        <p className="lede">
          RoadSense NS publishes road conditions, not people. This policy covers the RoadSense NS apps for
          iPhone and Android and this website, nsroadsense.ca. It explains what we collect, what we publish,
          how long we keep it, and how to reach us.
        </p>
        <p className="lede">
          Effective {POLICY_EFFECTIVE_DATE}. RoadSense NS is an independent, non-commercial community project
          run from Halifax, Nova Scotia. It isn&apos;t a government service.
        </p>
      </div>

      <article id="summary" className="content-card">
        <span className="eyebrow">01 · In short</span>
        <h2>The short version</h2>
        <ul className="content-bullets">
          <li>No account, no name, no ads, and we never sell data.</li>
          <li>The apps send road readings (location, time and a roughness measure) from drives.</li>
          <li>Privacy zones and the start and end of each drive are removed on your phone before upload.</li>
          <li>
            The public map only shows road-level averages, only for roads at least {MIN_CONTRIBUTORS_PUBLIC}{" "}
            different drivers have covered, and only with dates rounded to the day.
          </li>
          <li>Raw readings are deleted about 6–7 months after collection.</li>
        </ul>
      </article>

      <article id="collect" className="content-card">
        <span className="eyebrow">02 · What we collect</span>
        <h2>What the apps send us</h2>
        <h3>Road readings</h3>
        <p className="lede">
          While collection is on and you&apos;re driving, the app measures vibration with the phone&apos;s motion
          sensors and records location, speed, heading, GPS accuracy and time. Each uploaded reading is a short
          summary of a few seconds of driving at one point on the road. Readings upload automatically.
        </p>
        <h3>Pothole reports</h3>
        <p className="lede">
          If you mark a pothole, or confirm that one is still there or fixed, we receive the location, the time
          and what you reported.
        </p>
        <h3>Pothole photos (currently off)</h3>
        <p className="lede">
          The apps include an optional photo step for pothole reports. Photo uploads are switched off on our
          servers right now, so we don&apos;t receive any photos. We&apos;ll update this policy before turning
          them on.
        </p>
        <h3>A rotating device token</h3>
        <p className="lede">
          Uploads include a random token the app creates. It isn&apos;t your phone&apos;s serial number or an
          advertising ID, and it isn&apos;t linked to your name. The app replaces it about every 30 days. We use
          it to drop duplicate uploads, limit abuse, and count how many different contributors covered a road.
          Our servers store only a one-way hash of it.
        </p>
        <h3>Crash and error reports</h3>
        <p className="lede">
          The apps can send crash and error reports to Sentry: what went wrong and what the app was doing just
          before, the app version, the phone model and the operating-system version. They&apos;re not linked to
          your device token, and we configure them to leave out personal details.
        </p>
        <h3>Feedback you choose to send</h3>
        <p className="lede">
          If you send feedback from an app or this website, we receive your message, its category, the app or
          browser version, the platform, your language setting, and the screen or page you sent it from. A reply
          email is optional, and we only receive it if you type it in.
        </p>
        <h3>Network information</h3>
        <p className="lede">
          Like any internet service, our servers and Cloudflare see your IP address when the app or this
          website connects. We use it for rate limiting and to stop abuse. It is never part of the public data.
        </p>
        <h3>Device integrity checks (not switched on)</h3>
        <p className="lede">
          We&apos;re building optional checks (Apple App Attest and Google Play Integrity) that confirm uploads
          come from a genuine copy of the app, to keep fake data off the map. They aren&apos;t switched on yet,
          and we&apos;ll update this policy before they are.
        </p>
      </article>

      <article id="not-collected" className="content-card">
        <span className="eyebrow">03 · What we don&apos;t collect</span>
        <h2>No account, no profile, no ads</h2>
        <ul className="content-bullets">
          <li>No account or sign-up, and no name, phone number or home address.</li>
          <li>No contacts, photo library, microphone or calendar access.</li>
          <li>No advertising IDs, no ad networks, and no third-party analytics in the apps or on this website.</li>
          <li>No tracking of you across other apps or websites.</li>
          <li>We don&apos;t sell, rent or trade any data.</li>
        </ul>
      </article>

      <article id="on-device" className="content-card">
        <span className="eyebrow">04 · Protections on your phone</span>
        <h2>Private places are removed before upload</h2>
        <p className="lede">
          <strong>Privacy zones.</strong> You can add zones around home, work or anywhere else. Readings and
          pothole reports inside a zone are discarded on your phone. Our servers never receive them, and
          don&apos;t learn that a zone exists.
        </p>
        <p className="lede">
          <strong>Start and end trimming.</strong> The app also drops the first and last minute of every drive,
          and anything within 300 m of where the drive started or ended, so trip endpoints aren&apos;t uploaded.
          On Android, a drive ends when you stop collection, so add privacy zones for places you often park.
        </p>
        <p className="lede">
          <strong>You&apos;re in control.</strong> You can pause collection at any time, or turn off location or
          motion access in your phone&apos;s settings.
        </p>
      </article>

      <article id="public" className="content-card">
        <span className="eyebrow">05 · What&apos;s public</span>
        <h2>Only aggregated, road-level results</h2>
        <p className="lede">
          The public map and API show road-level results: a roughness category, a confidence level, how many
          readings and different contributors a road has, and pothole markers that at least two different
          devices have reported.
        </p>
        <div className="drawer-callout">
          <span className="eyebrow">Public data boundary</span>
          <strong>
            A road segment is published only after at least {MIN_CONTRIBUTORS_PUBLIC} different contributors
            have data on it, and public dates are rounded to the day.
          </strong>
          <span className="lede">
            Individual readings, drive traces, device tokens and per-contributor histories are never published.
          </span>
        </div>
        <p className="lede">
          The aggregated data is published under the{" "}
          <a href={ODBL_URL} target="_blank" rel="noopener noreferrer">
            Open Database License (ODbL) 1.0
          </a>
          , because it&apos;s built on OpenStreetMap road data.
        </p>
      </article>

      <article id="website" className="content-card">
        <span className="eyebrow">06 · This website</span>
        <h2>The website is read-only</h2>
        <p className="lede">
          This website doesn&apos;t use cookies, analytics or ad trackers, and doesn&apos;t ask for your location.
        </p>
        <p className="lede">
          The map is drawn with Mapbox. Your browser loads map tiles from Mapbox, so Mapbox receives your IP
          address and the map area you view. Mapbox&apos;s map library may also store a random identifier in your
          browser&apos;s local storage and send Mapbox basic usage events, which Mapbox uses for billing. If you
          use the place search, the text you type is sent to Mapbox to find matching places.
        </p>
      </article>

      <article id="retention" className="content-card">
        <span className="eyebrow">07 · How long we keep it</span>
        <h2>Retention by type of data</h2>
        <dl className="content-table">
          {retentionRows.map((row) => (
            <div key={row.data} className="content-table__row">
              <dt>{row.data}</dt>
              <dd>{row.kept}</dd>
            </div>
          ))}
        </dl>
      </article>

      <article id="processors" className="content-card">
        <span className="eyebrow">08 · Service providers</span>
        <h2>Who processes data for us</h2>
        <p className="lede">
          We use these service providers to run RoadSense NS. They process data on our behalf and don&apos;t
          get to use it for their own advertising.
        </p>
        <dl className="content-table">
          {processors.map((processor) => (
            <div key={processor.name} className="content-table__row">
              <dt>
                {processor.name}
                <span className="content-table__note">{processor.location}</span>
              </dt>
              <dd>{processor.role}</dd>
            </div>
          ))}
        </dl>
        <p className="lede">
          <strong>Cross-border processing.</strong> Your data is stored and processed outside Canada, mainly
          in the United States. While it&apos;s there, it&apos;s subject to the laws of that country, including
          lawful access by its courts and authorities.
        </p>
        <p className="lede">
          Apart from these providers and the public aggregated map, we share data only if the law requires it.
        </p>
      </article>

      <article id="your-rights" className="content-card">
        <span className="eyebrow">09 · Your choices and rights</span>
        <h2>Deleting data and making requests</h2>
        <p className="lede">
          <strong>On your phone:</strong> use Delete local contribution data in Settings on iPhone, or Delete
          local data in Settings on Android. Uninstalling the app also removes it.
        </p>
        <p className="lede">
          <strong>On our servers:</strong> you can ask to access, correct or delete your information by emailing{" "}
          <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a>. Because there are no accounts, we usually
          can&apos;t tell which readings came from you. If you tell us what you need, we&apos;ll explain what we
          can find and delete, and feedback can always be found by the email address you used. Readings are
          deleted automatically about 6–7 months after collection either way. We reply within 30 days.
        </p>
        <p className="lede">
          If you&apos;re not satisfied with our answer, you can complain to the{" "}
          <a href="https://www.priv.gc.ca/" target="_blank" rel="noopener noreferrer">
            Office of the Privacy Commissioner of Canada
          </a>
          .
        </p>
      </article>

      <article id="security" className="content-card">
        <span className="eyebrow">10 · Security</span>
        <h2>How we protect it</h2>
        <p className="lede">
          All traffic between the apps, this website and our servers is encrypted (HTTPS). Device tokens are
          stored only as one-way hashes, and access to the database is limited to the project maintainer. No
          system is perfectly secure. If a breach affects your information, we&apos;ll report it as Canadian
          privacy law requires.
        </p>
      </article>

      <article id="children" className="content-card">
        <span className="eyebrow">11 · Children</span>
        <h2>Not for children</h2>
        <p className="lede">
          RoadSense NS is meant for drivers and passengers, and isn&apos;t directed at children under 16. We
          don&apos;t knowingly collect personal information from children under 13. If you think a child has
          sent us something, such as feedback with an email address, contact us and we&apos;ll delete it.
        </p>
      </article>

      <article id="changes" className="content-card">
        <span className="eyebrow">12 · Changes</span>
        <h2>When this policy changes</h2>
        <p className="lede">
          If we change what we collect or publish, we&apos;ll update this page and its effective date first.
          For significant changes, we&apos;ll also say so in the app release notes.
        </p>
      </article>

      <article id="contact" className="content-card">
        <span className="eyebrow">13 · Contact</span>
        <h2>Questions and privacy requests</h2>
        <p className="lede">
          Email <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a> with privacy questions, requests or
          concerns. See also the <Link href="/terms">terms of use</Link> and the{" "}
          <Link href="/support">support page</Link>.
        </p>
      </article>
    </section>
  );
}
