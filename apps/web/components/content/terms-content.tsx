import Link from "next/link";

import { CONTACT_EMAIL, ODBL_URL, OSM_COPYRIGHT_URL, POLICY_EFFECTIVE_DATE } from "@/lib/site";

export function TermsContent() {
  return (
    <section className="content-page">
      <div className="content-card content-card--hero">
        <span className="eyebrow">Terms of use</span>
        <h1 className="content-heading">Terms of use</h1>
        <p className="lede">
          These terms cover the RoadSense NS apps for iPhone and Android, this website, and the public data
          they publish. By using RoadSense NS you agree to them. They&apos;re written to be read, so please do.
        </p>
        <p className="lede">Effective {POLICY_EFFECTIVE_DATE}.</p>
      </div>

      <article id="safety" className="content-card">
        <span className="eyebrow">01 · Safety first</span>
        <h2>Never handle your phone while driving</h2>
        <p className="lede">
          RoadSense collects in the background, so there&apos;s nothing to do while you drive. If you&apos;re the
          driver, don&apos;t touch the app while the vehicle is moving: marking potholes, taking photos and
          changing settings are for passengers, or for when you&apos;re safely stopped. Follow Nova
          Scotia&apos;s distracted-driving laws and mount your phone securely, or leave it out of reach.
        </p>
      </article>

      <article id="informational" className="content-card">
        <span className="eyebrow">02 · What the map is for</span>
        <h2>Informational only</h2>
        <p className="lede">
          RoadSense shows community-measured estimates of road roughness and reported potholes. The data is
          incomplete, can be out of date, and can be wrong. Don&apos;t use it for navigation, route planning
          around hazards, or any decision about safety. Always drive for the conditions in front of you.
        </p>
        <p className="lede">
          Report dangerous road conditions to the responsible public works department, or to emergency
          services if someone could be hurt. RoadSense doesn&apos;t forward reports to anyone.
        </p>
      </article>

      <article id="endorsement" className="content-card">
        <span className="eyebrow">03 · Independence</span>
        <h2>No government endorsement</h2>
        <p className="lede">
          RoadSense NS is an independent community project. It isn&apos;t run, funded or endorsed by the
          Province of Nova Scotia, any municipality, or any road authority, and its scores aren&apos;t official
          assessments.
        </p>
      </article>

      <article id="contributions" className="content-card">
        <span className="eyebrow">04 · Your contributions</span>
        <h2>The licence you give us</h2>
        <p className="lede">
          When you contribute readings, pothole reports or photos, you give RoadSense NS a worldwide,
          royalty-free, non-exclusive, perpetual licence to store, process, combine and publish them, and the
          results derived from them, as part of the public map and data. Our{" "}
          <Link href="/privacy">privacy policy</Link> explains how contributions are filtered and aggregated
          before anything is published.
        </p>
        <p className="lede">
          Only contribute data you collected yourself with the app. Don&apos;t upload fake, automated or
          manipulated data, and don&apos;t try to work out who contributed a reading.
        </p>
      </article>

      <article id="photos" className="content-card">
        <span className="eyebrow">05 · Photos</span>
        <h2>Rules for pothole photos</h2>
        <p className="lede">
          Photo uploads are switched off right now. When they&apos;re on, photos must show the road problem and
          nothing else of interest: no people&apos;s faces, licence plates, house numbers, or the inside of homes
          or vehicles. Take them only when it&apos;s safe and legal to do so, never while driving. Only upload
          photos you took. We may blur, decline or remove any photo.
        </p>
      </article>

      <article id="open-data" className="content-card">
        <span className="eyebrow">06 · Open data</span>
        <h2>Using RoadSense data</h2>
        <p className="lede">
          Road geometry comes from{" "}
          <a href={OSM_COPYRIGHT_URL} target="_blank" rel="noopener noreferrer">
            © OpenStreetMap contributors
          </a>
          . The aggregated RoadSense road data is derived from OpenStreetMap and is published under the{" "}
          <a href={ODBL_URL} target="_blank" rel="noopener noreferrer">
            Open Database License (ODbL) 1.0
          </a>
          . If you reuse it, credit &quot;RoadSense NS and © OpenStreetMap contributors&quot; and follow the
          ODbL&apos;s share-alike terms. Base map images are © Mapbox and © OpenStreetMap contributors and
          follow Mapbox&apos;s terms.
        </p>
        <p className="lede">
          Please be gentle with the public API: don&apos;t bulk-download tiles or data in ways that degrade
          the service for others. Email us if you need a larger extract.
        </p>
      </article>

      <article id="warranty" className="content-card">
        <span className="eyebrow">07 · No warranty</span>
        <h2>Provided as is</h2>
        <p className="lede">
          RoadSense NS is provided &quot;as is&quot; and &quot;as available&quot;, without warranties of any
          kind, including accuracy, completeness, availability or fitness for a particular purpose. To the
          fullest extent the law allows, RoadSense NS and its maintainers aren&apos;t liable for any loss or
          damage from using, or being unable to use, the apps, the website or the data. Nothing in these terms
          limits rights you have under consumer protection laws that can&apos;t be waived.
        </p>
        <p className="lede">
          We may change, pause or stop any part of RoadSense NS at any time, and may block access that abuses
          the service.
        </p>
      </article>

      <article id="law" className="content-card">
        <span className="eyebrow">08 · Governing law</span>
        <h2>Nova Scotia law applies</h2>
        <p className="lede">
          These terms are governed by the laws of Nova Scotia and the federal laws of Canada that apply there.
          Any dispute will be handled by the courts of Nova Scotia.
        </p>
      </article>

      <article id="changes" className="content-card">
        <span className="eyebrow">09 · Changes</span>
        <h2>When these terms change</h2>
        <p className="lede">
          We&apos;ll update this page and its effective date before changes take effect. If you keep using
          RoadSense NS after that, the new terms apply.
        </p>
      </article>

      <article id="contact" className="content-card">
        <span className="eyebrow">10 · Contact</span>
        <h2>Questions</h2>
        <p className="lede">
          Email <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a>. For help using the app, see the{" "}
          <Link href="/support">support page</Link>.
        </p>
      </article>
    </section>
  );
}
