import type { FreshnessState } from "@/lib/format";

type FreshnessPillProps = {
  label: string;
  state: FreshnessState;
};

export function FreshnessPill({ label, state }: FreshnessPillProps) {
  return (
    <span
      className="freshness-pill"
      data-state={state}
      role="status"
      aria-live="polite"
    >
      <span className="freshness-pill__dot" aria-hidden="true" />
      {label}
    </span>
  );
}
