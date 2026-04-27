import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { PrivacyAndCountsContent } from "@/components/content/privacy-and-counts-content";

function valueOf(testId: string, markup: string): string | null {
  const re = new RegExp(`data-testid="${testId}">([^<]*)<`);
  return markup.match(re)?.[1] ?? null;
}

function renderWithStats(stats: Partial<Parameters<typeof PrivacyAndCountsContent>[0]["stats"] & object> | null) {
  return renderToStaticMarkup(
    <PrivacyAndCountsContent
      stats={
        stats === null
          ? null
          : ({
              total_km_mapped: 0,
              total_readings: 0,
              segments_scored: 0,
              active_potholes: 0,
              municipalities_covered: 0,
              map_bounds: null,
              pothole_bounds: null,
              generated_at: null,
              ...stats,
            } as Parameters<typeof PrivacyAndCountsContent>[0]["stats"])
      }
    />,
  );
}

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

  describe("kilometre formatter edge cases", () => {
    it("renders sub-1km values in metres so the page never says '0 km' when there is data", () => {
      const markup = renderWithStats({ total_km_mapped: 0.3 });
      expect(valueOf("counts.km-mapped", markup)).toBe("300 m");
    });

    it("rounds metres to nearest integer for very small values", () => {
      expect(valueOf("counts.km-mapped", renderWithStats({ total_km_mapped: 0.0123 }))).toBe("12 m");
      expect(valueOf("counts.km-mapped", renderWithStats({ total_km_mapped: 0.0004 }))).toBe("0 m");
    });

    it("uses one decimal between 1 and 10 km", () => {
      expect(valueOf("counts.km-mapped", renderWithStats({ total_km_mapped: 1.04 }))).toBe("1.0 km");
      expect(valueOf("counts.km-mapped", renderWithStats({ total_km_mapped: 4.27 }))).toBe("4.3 km");
      expect(valueOf("counts.km-mapped", renderWithStats({ total_km_mapped: 9.99 }))).toBe("10.0 km");
    });

    it("uses comma-grouped integers for 10+ km", () => {
      expect(valueOf("counts.km-mapped", renderWithStats({ total_km_mapped: 10.4 }))).toBe("10 km");
      expect(valueOf("counts.km-mapped", renderWithStats({ total_km_mapped: 1245.7 }))).toBe("1,246 km");
      expect(valueOf("counts.km-mapped", renderWithStats({ total_km_mapped: 1_234_567 }))).toBe("1,234,567 km");
    });

    it("falls back to em-dash for nulls, infinities, NaN, and negatives", () => {
      expect(valueOf("counts.km-mapped", renderWithStats({ total_km_mapped: null as unknown as number }))).toBe("—");
      expect(valueOf("counts.km-mapped", renderWithStats({ total_km_mapped: Number.POSITIVE_INFINITY }))).toBe("—");
      expect(valueOf("counts.km-mapped", renderWithStats({ total_km_mapped: Number.NaN }))).toBe("—");
      expect(valueOf("counts.km-mapped", renderWithStats({ total_km_mapped: -1 }))).toBe("—");
    });
  });

  describe("count formatter edge cases", () => {
    it("formats large integers with thousand separators", () => {
      expect(valueOf("counts.total-readings", renderWithStats({ total_readings: 12345678 }))).toBe(
        "12,345,678",
      );
    });

    it("rounds fractional counts to nearest integer", () => {
      expect(valueOf("counts.segments-scored", renderWithStats({ segments_scored: 1.7 as unknown as number }))).toBe(
        "2",
      );
    });

    it("falls back to em-dash for null, undefined, infinity, and NaN", () => {
      expect(valueOf("counts.active-potholes", renderWithStats({ active_potholes: null as unknown as number }))).toBe(
        "—",
      );
      expect(
        valueOf("counts.active-potholes", renderWithStats({ active_potholes: Number.POSITIVE_INFINITY })),
      ).toBe("—");
      expect(valueOf("counts.active-potholes", renderWithStats({ active_potholes: Number.NaN }))).toBe("—");
    });
  });

  describe("generated_at formatter edge cases", () => {
    it("renders Halifax-tz absolute time for valid ISO input", () => {
      const markup = renderWithStats({
        generated_at: "2026-04-26T17:30:00Z",
      });
      const value = valueOf("counts.generated-at", markup);
      expect(value).not.toBe("—");
      expect(value).toMatch(/2026/);
    });

    it("falls back to em-dash for missing and unparseable strings", () => {
      expect(valueOf("counts.generated-at", renderWithStats({ generated_at: undefined }))).toBe("—");
      // Date with absurd input — Date constructor returns invalid, formatter must not throw.
      const markup = renderWithStats({ generated_at: "not-a-real-date" });
      const value = valueOf("counts.generated-at", markup);
      // Either falls back to em-dash, or echoes the raw string verbatim — never throws.
      expect(value === "—" || value === "not-a-real-date" || value === "Invalid Date").toBe(true);
    });
  });

  describe("partial stats objects", () => {
    it("renders mixed-validity rows independently without throwing", () => {
      const markup = renderWithStats({
        total_km_mapped: 12.4,
        segments_scored: null as unknown as number,
        active_potholes: 7,
        municipalities_covered: undefined as unknown as number,
        total_readings: 0,
      });
      expect(valueOf("counts.km-mapped", markup)).toBe("12 km");
      expect(valueOf("counts.segments-scored", markup)).toBe("—");
      expect(valueOf("counts.active-potholes", markup)).toBe("7");
      expect(valueOf("counts.municipalities-covered", markup)).toBe("—");
      expect(valueOf("counts.total-readings", markup)).toBe("0");
    });
  });
});
