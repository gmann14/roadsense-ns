export function MapLegend() {
  const items = [
    {
      className: "smooth",
      label: "Smooth",
      description: "Community readings suggest a comparatively steady road surface.",
    },
    {
      className: "fair",
      label: "Fair",
      description: "Noticeable roughness, but not among the harshest reported segments.",
    },
    {
      className: "rough",
      label: "Rough",
      description: "Consistently rough enough to stand out in the public signal.",
    },
    {
      className: "very-rough",
      label: "Very rough",
      description: "Among the harshest community-published road segments.",
    },
  ];

  return (
    <section className="card map-legend" aria-label="Road quality legend">
      <div style={{ display: "grid", gap: 8 }}>
        <span className="eyebrow">Legend</span>
        <strong>Road quality is a public aggregate, not a raw trip trace.</strong>
        <span className="lede">
          The map only publishes segments with enough contributor confidence to protect individual drivers.
        </span>
      </div>

      <ul className="legend-list">
        {items.map((item) => (
          <li key={item.label} className="legend-item">
            <span className={`legend-swatch ${item.className}`} aria-hidden="true" />
            <div style={{ display: "grid", gap: 4 }}>
              <strong>{item.label}</strong>
              <span className="lede" style={{ margin: 0, fontSize: "0.95rem" }}>
                {item.description}
              </span>
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}
