import { describe, expect, it } from "vitest";

import { formatPlainFreshness } from "@/lib/format";

const NOW = new Date("2026-05-05T15:00:00-03:00");

function daysAgo(n: number): string {
  const d = new Date(NOW);
  d.setUTCDate(d.getUTCDate() - n);
  return d.toISOString();
}

describe("formatPlainFreshness", () => {
  it("returns 'Updated today' when generated_at is the same Halifax day", () => {
    const sameDay = new Date("2026-05-05T03:00:00-03:00").toISOString();
    expect(formatPlainFreshness(sameDay, NOW)).toEqual({
      label: "Updated today",
      state: "fresh",
    });
  });

  it("returns 'Updated yesterday' for one day ago", () => {
    expect(formatPlainFreshness(daysAgo(1), NOW)).toEqual({
      label: "Updated yesterday",
      state: "fresh",
    });
  });

  it("returns 'Updated N days ago' between 2 and 14 days", () => {
    expect(formatPlainFreshness(daysAgo(5), NOW).label).toBe("Updated 5 days ago");
    expect(formatPlainFreshness(daysAgo(5), NOW).state).toBe("fresh");
  });

  it("returns 'Updated MMM D' past 14 days and marks the pill stale", () => {
    const result = formatPlainFreshness(daysAgo(30), NOW);
    expect(result.label).toMatch(/^Updated [A-Z][a-z]+ \d{1,2}$/);
    expect(result.state).toBe("stale");
  });

  it("returns the awaiting label for null", () => {
    expect(formatPlainFreshness(null, NOW)).toEqual({
      label: "Awaiting first publish",
      state: "pending",
    });
  });

  it("returns the awaiting label for an unparseable value", () => {
    expect(formatPlainFreshness("not-a-date", NOW)).toEqual({
      label: "Awaiting first publish",
      state: "pending",
    });
  });
});
