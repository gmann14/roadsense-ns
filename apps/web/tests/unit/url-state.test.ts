import { describe, expect, it } from "vitest";

import { parseViewportState } from "@/lib/url-state";

describe("parseViewportState viewport bounds", () => {
  it("accepts a valid, in-range viewport", () => {
    const state = parseViewportState(new URLSearchParams("lat=44.64&lng=-63.57&z=11.5"));

    expect(state.lat).toBe(44.64);
    expect(state.lng).toBe(-63.57);
    expect(state.z).toBe(11.5);
  });

  it("falls back to null when latitude is out of range", () => {
    // The crafted-URL crash: /?lat=95&lng=-63&z=9 used to be handed straight
    // to `new mapboxgl.Map(...)`, which throws on out-of-range coordinates.
    const state = parseViewportState(new URLSearchParams("lat=95&lng=-63&z=9"));

    expect(state.lat).toBeNull();
    expect(state.lng).toBeNull();
    expect(state.z).toBeNull();
  });

  it("falls back to null when longitude is out of range", () => {
    const state = parseViewportState(new URLSearchParams("lat=44&lng=-200&z=9"));

    expect(state.lat).toBeNull();
    expect(state.lng).toBeNull();
    expect(state.z).toBeNull();
  });

  it("falls back to null when zoom is out of range", () => {
    const state = parseViewportState(new URLSearchParams("lat=44&lng=-63&z=999"));

    expect(state.lat).toBeNull();
    expect(state.lng).toBeNull();
    expect(state.z).toBeNull();
  });

  it("falls back to null when zoom is negative", () => {
    const state = parseViewportState(new URLSearchParams("lat=44&lng=-63&z=-5"));

    expect(state.z).toBeNull();
  });

  it("falls back to null for garbage (non-numeric) values", () => {
    const state = parseViewportState(new URLSearchParams("lat=banana&lng=-63&z=9"));

    expect(state.lat).toBeNull();
    expect(state.lng).toBeNull();
    expect(state.z).toBeNull();
  });

  it("treats a partial viewport (missing one of lat/lng/z) as absent", () => {
    const state = parseViewportState(new URLSearchParams("lat=44&lng=-63"));

    expect(state.lat).toBeNull();
    expect(state.lng).toBeNull();
    expect(state.z).toBeNull();
  });

  it("accepts boundary values at the exact min/max", () => {
    const state = parseViewportState(new URLSearchParams("lat=-90&lng=180&z=0"));

    expect(state.lat).toBe(-90);
    expect(state.lng).toBe(180);
    expect(state.z).toBe(0);
  });

  it("leaves mode, segment, and q parsing unaffected", () => {
    const state = parseViewportState(new URLSearchParams("mode=potholes&segment=abc&q=Halifax&lat=999"));

    expect(state.mode).toBe("potholes");
    expect(state.segment).toBe("abc");
    expect(state.q).toBe("Halifax");
    expect(state.lat).toBeNull();
  });

  it("returns an all-null viewport when no params are present", () => {
    const state = parseViewportState(new URLSearchParams(""));

    expect(state).toEqual({
      mode: "quality",
      segment: null,
      lat: null,
      lng: null,
      z: null,
      q: null,
    });
  });
});
