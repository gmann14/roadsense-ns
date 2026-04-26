export function formatSnapshotDate(value: string | null | undefined): string {
  if (!value) {
    return "Pending";
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }

  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Halifax",
    month: "short",
    day: "numeric",
  }).format(date);
}
