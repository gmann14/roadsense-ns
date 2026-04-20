type TrustStripProps = {
  totalKmMapped: string;
  municipalitiesCovered: string;
  freshness: string;
};

export function TrustStrip({
  totalKmMapped,
  municipalitiesCovered,
  freshness,
}: TrustStripProps) {
  return (
    <section
      className="card"
      aria-label="Trust summary"
      style={{
        display: "grid",
        gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))",
        gap: 14,
        padding: 18,
        marginBottom: 18,
      }}
    >
      <TrustMetric label="Mapped distance" value={totalKmMapped} />
      <TrustMetric label="Municipalities covered" value={municipalitiesCovered} />
      <TrustMetric label="Last refresh" value={freshness} />
    </section>
  );
}

function TrustMetric({ label, value }: { label: string; value: string }) {
  return (
    <div style={{ display: "grid", gap: 4 }}>
      <span className="eyebrow">{label}</span>
      <strong style={{ fontSize: "1.15rem" }}>{value}</strong>
    </div>
  );
}
