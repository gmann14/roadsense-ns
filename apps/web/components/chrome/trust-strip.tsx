import { formatSnapshotDate } from "@/lib/format";

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
    <section className="card trust-strip" aria-label="Trust summary">
      <TrustMetric label="Unique road coverage" value={totalKmMapped} />
      <TrustMetric label="Municipalities covered" value={municipalitiesCovered} />
      <TrustMetric label="Last refresh" value={formatSnapshotDate(freshness)} />
    </section>
  );
}

function TrustMetric({ label, value }: { label: string; value: string }) {
  return (
    <div className="trust-strip__metric">
      <span className="eyebrow">{label}</span>
      <strong className="num">{value}</strong>
    </div>
  );
}
