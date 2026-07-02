export default function Loading() {
  return (
    <div
      role="status"
      aria-live="polite"
      style={{
        display: "grid",
        placeItems: "center",
        minHeight: "60vh",
        gap: 12,
        color: "var(--rs-ink-muted)",
      }}
    >
      <span className="eyebrow">RoadSense NS</span>
      <strong style={{ fontFamily: "var(--rs-font-display)", fontSize: "1.2rem" }}>Loading the map…</strong>
    </div>
  );
}
