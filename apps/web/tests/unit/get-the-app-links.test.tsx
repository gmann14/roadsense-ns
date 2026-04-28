import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { GetTheAppLinks, readAppStoreLinks } from "@/components/chrome/get-the-app-links";

const ORIGINAL_IOS = process.env.NEXT_PUBLIC_APP_STORE_URL;
const ORIGINAL_ANDROID = process.env.NEXT_PUBLIC_PLAY_STORE_URL;

beforeEach(() => {
  delete process.env.NEXT_PUBLIC_APP_STORE_URL;
  delete process.env.NEXT_PUBLIC_PLAY_STORE_URL;
});

afterEach(() => {
  if (ORIGINAL_IOS === undefined) delete process.env.NEXT_PUBLIC_APP_STORE_URL;
  else process.env.NEXT_PUBLIC_APP_STORE_URL = ORIGINAL_IOS;
  if (ORIGINAL_ANDROID === undefined) delete process.env.NEXT_PUBLIC_PLAY_STORE_URL;
  else process.env.NEXT_PUBLIC_PLAY_STORE_URL = ORIGINAL_ANDROID;
});

describe("readAppStoreLinks", () => {
  it("returns nulls when neither env var is set", () => {
    expect(readAppStoreLinks()).toEqual({ iosURL: null, androidURL: null });
  });

  it("treats whitespace-only env vars as unset", () => {
    process.env.NEXT_PUBLIC_APP_STORE_URL = "   ";
    process.env.NEXT_PUBLIC_PLAY_STORE_URL = "";
    expect(readAppStoreLinks()).toEqual({ iosURL: null, androidURL: null });
  });

  it("trims and returns configured URLs", () => {
    process.env.NEXT_PUBLIC_APP_STORE_URL = "  https://apps.apple.com/app/id12345 ";
    process.env.NEXT_PUBLIC_PLAY_STORE_URL = "https://play.google.com/store/apps/details?id=ca.roadsense";
    expect(readAppStoreLinks()).toEqual({
      iosURL: "https://apps.apple.com/app/id12345",
      androidURL: "https://play.google.com/store/apps/details?id=ca.roadsense",
    });
  });
});

describe("GetTheAppLinks", () => {
  it("renders nothing when neither URL is configured", () => {
    const markup = renderToStaticMarkup(<GetTheAppLinks />);
    expect(markup).toBe("");
  });

  it("renders only the iOS pill when only the App Store URL is set", () => {
    process.env.NEXT_PUBLIC_APP_STORE_URL = "https://apps.apple.com/app/id12345";

    const markup = renderToStaticMarkup(<GetTheAppLinks />);

    expect(markup).toContain("App Store");
    expect(markup).not.toContain("Google Play");
    expect(markup).toContain('href="https://apps.apple.com/app/id12345"');
    expect(markup).toContain('target="_blank"');
    expect(markup).toContain('rel="noopener noreferrer"');
    expect(markup).toContain('data-testid="get-the-app.ios"');
    expect(markup).not.toContain('data-testid="get-the-app.android"');
  });

  it("renders only the Android pill when only the Play Store URL is set", () => {
    process.env.NEXT_PUBLIC_PLAY_STORE_URL = "https://play.google.com/store/apps/details?id=ca.roadsense";

    const markup = renderToStaticMarkup(<GetTheAppLinks />);

    expect(markup).toContain("Google Play");
    expect(markup).not.toContain("App Store");
    expect(markup).toContain('href="https://play.google.com/store/apps/details?id=ca.roadsense"');
    expect(markup).toContain('data-testid="get-the-app.android"');
    expect(markup).not.toContain('data-testid="get-the-app.ios"');
  });

  it("renders both pills when both URLs are configured", () => {
    process.env.NEXT_PUBLIC_APP_STORE_URL = "https://apps.apple.com/app/id12345";
    process.env.NEXT_PUBLIC_PLAY_STORE_URL = "https://play.google.com/store/apps/details?id=ca.roadsense";

    const markup = renderToStaticMarkup(<GetTheAppLinks />);

    expect(markup).toContain('data-testid="get-the-app.ios"');
    expect(markup).toContain('data-testid="get-the-app.android"');
    expect(markup).toContain("App Store");
    expect(markup).toContain("Google Play");
  });

  it("renders the card variant heading when variant=card", () => {
    process.env.NEXT_PUBLIC_APP_STORE_URL = "https://apps.apple.com/app/id12345";

    const markup = renderToStaticMarkup(<GetTheAppLinks variant="card" />);

    expect(markup).toContain('class="get-the-app__heading">Get the RoadSense app</p>');
  });

  it("does not include the visible heading paragraph by default", () => {
    process.env.NEXT_PUBLIC_APP_STORE_URL = "https://apps.apple.com/app/id12345";

    const markup = renderToStaticMarkup(<GetTheAppLinks />);

    // aria-label is always present (a11y), but the visible <p> heading only
    // shows in the card variant.
    expect(markup).not.toContain('class="get-the-app__heading"');
  });
});
