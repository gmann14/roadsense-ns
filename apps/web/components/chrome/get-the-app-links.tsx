type Props = {
  className?: string;
  variant?: "inline" | "card";
};

export type AppStoreLinks = {
  iosURL: string | null;
  androidURL: string | null;
};

export function readAppStoreLinks(): AppStoreLinks {
  const ios = process.env.NEXT_PUBLIC_APP_STORE_URL?.trim();
  const android = process.env.NEXT_PUBLIC_PLAY_STORE_URL?.trim();
  return {
    iosURL: ios && ios.length > 0 ? ios : null,
    androidURL: android && android.length > 0 ? android : null,
  };
}

/**
 * Conditionally renders App Store / Play Store links.
 *
 * Renders nothing while both URLs are unset (the typical "pre-launch" state)
 * so the marketing surface never advertises a destination that doesn't exist.
 * As soon as one URL is configured the corresponding pill appears.
 */
export function GetTheAppLinks({ className, variant = "inline" }: Props) {
  const { iosURL, androidURL } = readAppStoreLinks();

  if (!iosURL && !androidURL) {
    return null;
  }

  const wrapperClass = variant === "card" ? "get-the-app card" : "get-the-app";

  return (
    <section
      className={[wrapperClass, className].filter(Boolean).join(" ")}
      aria-label="Get the RoadSense app"
      data-testid="get-the-app"
    >
      {variant === "card" ? (
        <p className="get-the-app__heading">Get the RoadSense app</p>
      ) : null}

      <div className="get-the-app__pills">
        {iosURL ? (
          <a
            href={iosURL}
            className="get-the-app__pill get-the-app__pill--ios"
            target="_blank"
            rel="noopener noreferrer"
            data-testid="get-the-app.ios"
          >
            <AppleGlyph />
            <span>
              <span className="get-the-app__line1">Download on the</span>
              <span className="get-the-app__line2">App Store</span>
            </span>
          </a>
        ) : null}

        {androidURL ? (
          <a
            href={androidURL}
            className="get-the-app__pill get-the-app__pill--android"
            target="_blank"
            rel="noopener noreferrer"
            data-testid="get-the-app.android"
          >
            <PlayGlyph />
            <span>
              <span className="get-the-app__line1">Get it on</span>
              <span className="get-the-app__line2">Google Play</span>
            </span>
          </a>
        ) : null}
      </div>
    </section>
  );
}

function AppleGlyph() {
  return (
    <svg
      width="20"
      height="20"
      viewBox="0 0 24 24"
      fill="currentColor"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M16.36 1.65c0 1.04-.36 2.01-1.07 2.92-.86 1.08-1.92 1.7-3.07 1.6a3.5 3.5 0 0 1-.04-.42c0-1 .42-2.07 1.16-2.96.37-.45.84-.83 1.41-1.13.57-.31 1.11-.47 1.62-.5 0 .17 0 .33-.01.49ZM20.5 17.43c-.5 1.18-.74 1.71-1.4 2.76-.91 1.45-2.2 3.27-3.79 3.28-1.42.01-1.79-.93-3.72-.92-1.93.01-2.33.94-3.75.92-1.6-.01-2.81-1.65-3.73-3.1-2.55-4.07-2.82-8.86-1.25-11.4 1.12-1.81 2.88-2.86 4.54-2.86 1.69 0 2.75.93 4.15.93 1.36 0 2.18-.93 4.13-.93 1.48 0 3.04.81 4.16 2.21-3.66 2-3.07 7.23.66 9.11Z" />
    </svg>
  );
}

function PlayGlyph() {
  return (
    <svg
      width="20"
      height="20"
      viewBox="0 0 24 24"
      aria-hidden="true"
      focusable="false"
    >
      <path
        d="M3.6 2.5c-.4.3-.6.7-.6 1.3v16.4c0 .6.2 1 .6 1.3l9.7-9.5L3.6 2.5Z"
        fill="#34A853"
      />
      <path
        d="M16.6 8.7 13.3 12l3.3 3.3 4-2.3c1.1-.6 1.1-2.3 0-3l-4-2.3Z"
        fill="#FBBC04"
      />
      <path
        d="M3.6 2.5 13.3 12 3.6 2.5c-.1 0-.2.1-.2.3.1-.1.1-.2.2-.3Z"
        fill="#EA4335"
      />
      <path
        d="m3.6 21.5 9.7-9.5-9.7-9.5c-.1.1-.2.2-.2.3v18.4c0 .1.1.2.2.3Z"
        fill="#4285F4"
      />
    </svg>
  );
}
