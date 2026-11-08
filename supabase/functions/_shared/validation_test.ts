import { assertEquals } from "jsr:@std/assert";
import { isRfc3339Timestamp } from "./validation.ts";

Deno.test("isRfc3339Timestamp accepts the formats iOS, Android and the web send", () => {
    for (
        const value of [
            "2026-04-17T14:30:00Z",
            "2026-04-17T14:28:14.321Z",
            "2026-04-17T14:28:14.123456789Z",
            "2026-04-17T11:28:14-03:00",
            "2026-04-17T14:28:14+00:00",
            "2028-02-29T00:00:00Z",
        ]
    ) {
        assertEquals(isRfc3339Timestamp(value), true, value);
    }
});

Deno.test("isRfc3339Timestamp rejects values Date.parse would accept", () => {
    for (
        const value of [
            "0",
            "2026",
            "2026-04-17",
            "April 17, 2026",
            "2026-04-17 14:30:00Z",
            "2026-04-17T14:30:00",
            "2026-04-17T14:30Z",
            "2026-04-17t14:30:00z",
            "2026-02-30T00:00:00Z",
            "2027-02-29T00:00:00Z",
            "2026-13-01T00:00:00Z",
            "2026-04-17T24:00:00Z",
            "2026-04-17T14:60:00Z",
            "2026-04-17T14:30:60Z",
            "2026-04-17T14:30:00+24:00",
            "2026-04-17T14:30:00.Z",
            "0000-01-01T00:00:00Z",
            " 2026-04-17T14:30:00Z",
            "",
        ]
    ) {
        assertEquals(isRfc3339Timestamp(value), false, value);
    }
});

Deno.test("isRfc3339Timestamp rejects non-strings", () => {
    for (const value of [null, undefined, 1713364200000, {}, []]) {
        assertEquals(isRfc3339Timestamp(value), false);
    }
});
