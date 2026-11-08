// Strict RFC 3339 timestamp check (review 2026-10-18, "Lenient timestamp
// parsing").
//
// `Date.parse` accepts far more than RFC 3339 ("0", "2026", "April 1",
// "2026-02-31T00:00:00Z" rolled over to March), and Postgres rejects several
// of those on the `::timestamptz` cast, so a malformed timestamp surfaced as
// a 502 processing_failed instead of a 400. This requires the full
// date-time-with-offset form and real calendar/clock values. The `T` and `Z`
// must be uppercase (RFC 3339 §5.6 lets applications restrict them, and
// every client already sends uppercase).

const RFC3339_RE =
    /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d{1,9})?(Z|([+-])(\d{2}):(\d{2}))$/;

function daysInMonth(year: number, month: number): number {
    return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

export function isRfc3339Timestamp(value: unknown): value is string {
    if (typeof value !== "string") return false;
    const match = RFC3339_RE.exec(value);
    if (!match) return false;

    const year = Number(match[1]);
    const month = Number(match[2]);
    const day = Number(match[3]);
    const hour = Number(match[4]);
    const minute = Number(match[5]);
    const second = Number(match[6]);

    if (year < 1 || month < 1 || month > 12) return false;
    if (day < 1 || day > daysInMonth(year, month)) return false;
    // Leap seconds (:60) are legal RFC 3339 but no client emits them and
    // Postgres would roll them over; reject rather than silently shift.
    if (hour > 23 || minute > 59 || second > 59) return false;

    if (match[9] !== undefined) {
        const offsetHours = Number(match[10]);
        const offsetMinutes = Number(match[11]);
        if (offsetHours > 23 || offsetMinutes > 59) return false;
    }

    return !Number.isNaN(Date.parse(value));
}
