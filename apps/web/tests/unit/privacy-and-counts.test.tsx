import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { PrivacyAndCountsContent } from "@/components/content/privacy-and-counts-content";

describe("PrivacyAndCountsContent", () => {
  it("formats live counts and generated_at when stats are available", () => {
    const markup = renderToStaticMarkup(
      <PrivacyAndCountsContent
        stats={{
          total_km_mapped: 1245.7,
          total_readings: 482003,
          segments_scored: 1820,
          active_potholes: 47,
          municipalities_covered: 9,
          map_bounds: null,
          pothole_bounds: null,
          generated_at: "2026-04-26T17:30:00Z",
        }}
      />,
    );

    // Halifax tz-aware formatting
    expect(markup).toContain('data-testid="counts.km-mapped">1,246 km');
    expect(markup).toContain('data-testid="counts.segments-scored">1,820');
    expect(markup).toContain('data-testid="counts.active-potholes">47');
    expect(markup).toContain('data-testid="counts.municipalities-covered">9');
    expect(markup).toContain('data-testid="counts.total-readings">482,003');
    expect(markup).toContain('data-testid="counts.generated-at"');
  });

  it("falls back to em-dashes when stats are unavailable", () => {
    const markup = renderToStaticMarkup(<PrivacyAndCountsContent stats={null} />);

    expect(markup).toContain('data-testid="counts.km-mapped">—');
    expect(markup).toContain('data-testid="counts.segments-scored">—');
    expect(markup).toContain('data-testid="counts.generated-at">—');
  });

  it("names every documented telemetry source", () => {
    const markup = renderToStaticMarkup(<PrivacyAndCountsContent stats={null} />);

    for (const source of [
      "readings",
      "segment_aggregates",
      "pothole_reports",
      "pothole_actions",
      "pothole_photos",
      "feedback_submissions",
      "device_tokens",
      "rate_limits",
      "Mapbox",
      "Sentry",
      "Vercel",
    ]) {
      expect(markup, `expected ${source} to be named`).toContain(source);
    }
  });

  it("explicitly disclaims unsupported telemetry brands", () => {
    const markup = renderToStaticMarkup(<PrivacyAndCountsContent stats={null} />);

    for (const banned of ["Firebase", "Mixpanel", "Amplitude", "PostHog cloud", "Segment"]) {
      expect(markup, `expected ${banned} to appear in the disclaimer`).toContain(banned);
    }
  });
});
