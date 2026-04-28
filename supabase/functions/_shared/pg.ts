// Tiny shared helpers for the per-handler pgRuntime files. postgres-deno
// returns Date for timestamptz columns and string for numerics; both helpers
// normalise to the JSON shape our handlers want.

export function toIso(value: Date | string | null | undefined): string | null {
    if (!value) return null;
    return value instanceof Date ? value.toISOString() : String(value);
}
