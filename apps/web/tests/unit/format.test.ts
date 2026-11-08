import { describe, expect, it } from "vitest";

import { formatCalendarDate, formatCount, formatPlainFreshness } from "@/lib/format";

const NOW = new Date("2026-05-05T15:00:00-03:00");

function daysAgo(n: number): string {
  const d = new Date(NOW);
  d.setUTCDate(d.getUTCDate() - n);
  return d.toISOString();
}

describe("formatPlainFreshness", () => {
  it("returns 'Updated today' when the data changed the same Halifax day", () => {
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
    expect(formatPlainFreshness(daysAgo(5), NOW)?.label).toBe("Updated 5 days ago");
    expect(formatPlainFreshness(daysAgo(5), NOW)?.state).toBe("fresh");
  });

  it("returns 'Updated MMM D' past 14 days and marks the pill stale", () => {
    const result = formatPlainFreshness(daysAgo(30), NOW);
    expect(result?.label).toMatch(/^Updated [A-Z][a-z]+\.? \d{1,2}$/);
    expect(result?.state).toBe("stale");
  });

  it("treats a day-rounded date as that calendar day, not the previous Halifax evening", () => {
    expect(formatPlainFreshness("2026-05-05", NOW)?.label).toBe("Updated today");
    expect(formatPlainFreshness("2026-05-05T00:00:00Z", NOW)?.label).toBe("Updated today");
    expect(formatPlainFreshness("2026-05-04T00:00:00+00:00", NOW)?.label).toBe("Updated yesterday");
  });

  it("returns null (hide the pill) for missing or unparseable values", () => {
    expect(formatPlainFreshness(null, NOW)).toBeNull();
    expect(formatPlainFreshness(undefined, NOW)).toBeNull();
    expect(formatPlainFreshness("", NOW)).toBeNull();
    expect(formatPlainFreshness("not-a-date", NOW)).toBeNull();
  });
});

describe("formatCount", () => {
  it("groups thousands the Canadian English way regardless of runtime locale", () => {
    expect(formatCount(1234567)).toBe("1,234,567");
    expect(formatCount(519.6)).toBe("520");
  });

  it("renders a dash for missing values", () => {
    expect(formatCount(null)).toBe("—");
    expect(formatCount(undefined)).toBe("—");
    expect(formatCount(Number.NaN)).toBe("—");
  });
});

describe("formatCalendarDate", () => {
  it("formats day-rounded values without shifting them a day earlier", () => {
    expect(formatCalendarDate("2026-11-08")).toBe("Nov 8, 2026");
    expect(formatCalendarDate("2026-11-08T00:00:00Z")).toBe("Nov 8, 2026");
  });

  it("reads full timestamps in Nova Scotia time", () => {
    // 02:30 UTC on Nov 9 is still the evening of Nov 8 in Halifax.
    expect(formatCalendarDate("2026-11-09T02:30:00Z")).toBe("Nov 8, 2026");
  });

  it("returns null for missing or invalid values", () => {
    expect(formatCalendarDate(null)).toBeNull();
    expect(formatCalendarDate("garbage")).toBeNull();
  });
});
