import Link from "next/link";

import { CONTACT_EMAIL, MIN_CONTRIBUTORS_PUBLIC } from "@/lib/site";

type Faq = { id: string; question: string; answer: React.ReactNode };

const faqs: Faq[] = [
  {
    id: "battery",
    question: "Will it drain my battery?",
    answer: (
      <>
        RoadSense uses GPS and motion sensors only while a drive is being collected, and pauses itself if the
        phone gets too hot. Long drives use more battery, like any navigation app, so plug in for long trips.
        You can pause collection at any time.
      </>
    ),
  },
  {
    id: "privacy-zones",
    question: "What are privacy zones?",
    answer: (
      <>
        Circles you draw around home, work or anywhere else you&apos;d rather not share. Readings and pothole
        reports inside a zone are discarded on your phone and never uploaded. The app also drops the first and
        last minute of every drive and anything within 300 m of where it started or ended. Add zones in the
        app&apos;s Settings.
      </>
    ),
  },
  {
    id: "my-roads",
    question: "Why don't my roads show up on the map yet?",
    answer: (
      <>
        A road appears only after at least {MIN_CONTRIBUTORS_PUBLIC} different drivers have covered it. That
        protects contributors: one person&apos;s commute can&apos;t be picked out of the map. Readings also
        need a few minutes to upload and be matched to roads, and slow driving (under 15 km/h), poor GPS, and
        trip starts and ends are filtered out. Your own drives still count toward the totals in the app.
      </>
    ),
  },
  {
    id: "delete-local",
    question: "How do I delete the data on my phone?",
    answer: (
      <>
        On iPhone, open Settings in the app and tap Delete local contribution data. On Android, open Settings
        in the app and tap Delete local data. Uninstalling the app also removes it.
      </>
    ),
  },
  {
    id: "delete-server",
    question: "How do I ask for my data to be deleted from your servers?",
    answer: (
      <>
        Email <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a>. There are no accounts, so we usually
        can&apos;t tell which readings are yours, but we&apos;ll tell you what we can find and delete, and
        feedback can always be found by the email you used. Uploaded readings are deleted automatically about
        6–7 months after collection either way. The{" "}
        <Link href="/privacy#your-rights">privacy policy</Link> has the details.
      </>
    ),
  },
  {
    id: "platforms",
    question: "Is it on iPhone and Android?",
    answer: (
      <>
        RoadSense NS is being tested on iPhone through TestFlight, and an Android version is in development.
        Store links will appear on this site once each version is publicly available. The map on this website
        works in any modern browser.
      </>
    ),
  },
  {
    id: "safety",
    question: "Do I need to do anything while driving?",
    answer: (
      <>
        No, and please don&apos;t. Collection runs in the background. If you&apos;re driving, leave the phone
        alone; marking potholes is for passengers or when you&apos;re safely stopped. See the{" "}
        <Link href="/terms#safety">terms of use</Link>.
      </>
    ),
  },
  {
    id: "report-hazard",
    question: "Does RoadSense report potholes to the city or province?",
    answer: (
      <>
        No. RoadSense isn&apos;t connected to any government, and reports aren&apos;t forwarded. Report hazards
        to the responsible public works department, or call emergency services if someone could be hurt.
      </>
    ),
  },
];

export function SupportContent() {
  return (
    <section className="content-page">
      <div className="content-card content-card--hero">
        <span className="eyebrow">Support</span>
        <h1 className="content-heading">RoadSense NS help</h1>
        <p className="lede">
          RoadSense NS turns everyday drives into a public map of road roughness and potholes across Nova
          Scotia. While you drive, the app measures vibration with your phone&apos;s motion sensors and GPS,
          filters out private places on the phone, and uploads road readings. The server combines readings from
          many drivers into the road-level averages you see on the <Link href="/">map</Link>.
        </p>
      </div>

      <article id="faq" className="content-card">
        <span className="eyebrow">Questions</span>
        <h2>Frequently asked questions</h2>
        <div className="content-faq">
          {faqs.map((faq) => (
            <details key={faq.id} id={faq.id}>
              <summary>{faq.question}</summary>
              <p className="lede">{faq.answer}</p>
            </details>
          ))}
        </div>
      </article>

      <article id="contact" className="content-card">
        <span className="eyebrow">Contact</span>
        <h2>Still stuck?</h2>
        <p className="lede">
          Email <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a>, or use Send feedback at the top of
          this page or in the app. Tell us your phone model and app version if something isn&apos;t working.
          We&apos;re a small volunteer project and usually reply within a few days.
        </p>
        <p className="lede">
          Read more: <Link href="/methodology">how the map is built</Link> ·{" "}
          <Link href="/privacy">privacy policy</Link> · <Link href="/terms">terms of use</Link>
        </p>
      </article>
    </section>
  );
}
