"use client";

import { useEffect } from "react";

type ErrorPageProps = {
  error: Error & { digest?: string };
  reset: () => void;
};

export default function ErrorPage({ error, reset }: ErrorPageProps) {
  useEffect(() => {
    // Log to the browser console without rendering internals to the public
    // page. The website has no error-reporting service installed.
    console.error("RoadSense NS: unhandled page error", error);
  }, [error]);

  return (
    <div className="page-shell">
      <main id="main-content">
        <section className="content-page">
          <div className="content-card content-card--hero">
            <span className="eyebrow">Something went sideways</span>
            <h1 className="headline">The map hit a pothole.</h1>
            <p className="lede">
              This page ran into an unexpected error. It&apos;s on our side, not yours — try reloading the page.
              If it keeps happening, let us know what you were doing.
            </p>
            <div style={{ display: "flex", gap: 12, flexWrap: "wrap", marginTop: 8 }}>
              <button type="button" onClick={reset} className="btn btn-primary">
                Try again
              </button>
              <a href="/" className="btn btn-secondary">
                Back to the map
              </a>
            </div>
          </div>
        </section>
      </main>
    </div>
  );
}
