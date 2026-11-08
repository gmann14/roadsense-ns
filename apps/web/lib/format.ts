export type FreshnessState = "fresh" | "stale";

export type FreshnessResult = {
  label: string;
  state: FreshnessState;
};

export const DISPLAY_LOCALE = "en-CA";
export const HALIFAX_TZ = "America/Halifax";
export const PLACEHOLDER = "—";

const STALE_AFTER_DAYS = 14;
const MS_PER_DAY = 24 * 60 * 60 * 1000;
const DATE_ONLY_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/;

const countFormatter = new Intl.NumberFormat(DISPLAY_LOCALE, { maximumFractionDigits: 0 });

/**
 * Plain-language freshness label for the data itself (when road aggregates
 * last changed), not for when a cache or materialized view was refreshed.
 * Returns null when there is no trustworthy timestamp, so callers can hide the
 * signal instead of guessing.
 */
export function formatPlainFreshness(
  value: string | null | undefined,
  now: Date = new Date(),
): FreshnessResult | null {
  const dayKey = toDayKey(value);
  if (dayKey === null) {
    return null;
  }

  const days = Math.round((halifaxDayKey(now) - dayKey) / MS_PER_DAY);

  if (days <= 0) {
    return { label: "Updated today", state: "fresh" };
  }

  if (days === 1) {
    return { label: "Updated yesterday", state: "fresh" };
  }

  if (days <= STALE_AFTER_DAYS) {
    return { label: `Updated ${days} days ago`, state: "fresh" };
  }

  return { label: `Updated ${formatDayKey(dayKey, { month: "short", day: "numeric" })}`, state: "stale" };
}

/** Whole-number count with Canadian English grouping ("12,345"), or a dash. */
export function formatCount(value: number | null | undefined): string {
  if (value === null || value === undefined || !Number.isFinite(value)) {
    return PLACEHOLDER;
  }
  return countFormatter.format(Math.round(value));
}

/** Decimal with a fixed number of digits in Canadian English ("1,234.50"), or a dash. */
export function formatDecimal(value: number | null | undefined, digits: number): string {
  if (value === null || value === undefined || !Number.isFinite(value)) {
    return PLACEHOLDER;
  }
  return new Intl.NumberFormat(DISPLAY_LOCALE, {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(value);
}

/**
 * Calendar date such as "Nov 8, 2026". Public timestamps are rounded to the
 * day server-side, so date-only strings and exact-UTC-midnight timestamps are
 * treated as calendar days (no time-zone shift); other timestamps are read in
 * Nova Scotia time. Returns null for missing or unparseable input.
 */
export function formatCalendarDate(value: string | null | undefined): string | null {
  const dayKey = toDayKey(value);
  if (dayKey === null) {
    return null;
  }
  return formatDayKey(dayKey, { month: "short", day: "numeric", year: "numeric" });
}

/** Milliseconds at UTC midnight of the calendar day a value represents. */
function toDayKey(value: string | null | undefined): number | null {
  if (typeof value !== "string" || value.trim().length === 0) {
    return null;
  }

  const trimmed = value.trim();
  const dateOnly = DATE_ONLY_PATTERN.exec(trimmed);
  if (dateOnly) {
    const key = Date.UTC(Number(dateOnly[1]), Number(dateOnly[2]) - 1, Number(dateOnly[3]));
    return Number.isNaN(key) ? null : key;
  }

  const parsed = new Date(trimmed);
  if (Number.isNaN(parsed.getTime())) {
    return null;
  }

  if (isUtcMidnight(parsed)) {
    return Date.UTC(parsed.getUTCFullYear(), parsed.getUTCMonth(), parsed.getUTCDate());
  }

  return halifaxDayKey(parsed);
}

function isUtcMidnight(date: Date): boolean {
  return (
    date.getUTCHours() === 0 &&
    date.getUTCMinutes() === 0 &&
    date.getUTCSeconds() === 0 &&
    date.getUTCMilliseconds() === 0
  );
}

function halifaxDayKey(date: Date): number {
  const parts = new Intl.DateTimeFormat(DISPLAY_LOCALE, {
    timeZone: HALIFAX_TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const lookup = (type: string) => parts.find((part) => part.type === type)?.value ?? "";
  return Date.UTC(Number(lookup("year")), Number(lookup("month")) - 1, Number(lookup("day")));
}

function formatDayKey(dayKey: number, options: Intl.DateTimeFormatOptions): string {
  return new Intl.DateTimeFormat(DISPLAY_LOCALE, { ...options, timeZone: "UTC" }).format(new Date(dayKey));
}
