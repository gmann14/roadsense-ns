export type FreshnessState = "fresh" | "stale" | "pending";

export type FreshnessResult = {
  label: string;
  state: FreshnessState;
};

const HALIFAX_TZ = "America/Halifax";
const STALE_AFTER_DAYS = 14;
const MS_PER_DAY = 24 * 60 * 60 * 1000;

export function formatPlainFreshness(
  value: string | null | undefined,
  now: Date = new Date(),
): FreshnessResult {
  if (!value) {
    return { label: "Awaiting first publish", state: "pending" };
  }

  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return { label: "Awaiting first publish", state: "pending" };
  }

  const days = halifaxDayDelta(parsed, now);

  if (days <= 0) {
    return { label: "Updated today", state: "fresh" };
  }

  if (days === 1) {
    return { label: "Updated yesterday", state: "fresh" };
  }

  if (days <= STALE_AFTER_DAYS) {
    return { label: `Updated ${days} days ago`, state: "fresh" };
  }

  const formatted = new Intl.DateTimeFormat("en-CA", {
    timeZone: HALIFAX_TZ,
    month: "short",
    day: "numeric",
  }).format(parsed);

  return { label: `Updated ${formatted}`, state: "stale" };
}

function halifaxDayDelta(then: Date, now: Date): number {
  const thenMidnight = halifaxMidnightUtc(then);
  const nowMidnight = halifaxMidnightUtc(now);
  return Math.round((nowMidnight - thenMidnight) / MS_PER_DAY);
}

function halifaxMidnightUtc(date: Date): number {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: HALIFAX_TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const lookup = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
  return Date.UTC(
    Number(lookup("year")),
    Number(lookup("month")) - 1,
    Number(lookup("day")),
  );
}

