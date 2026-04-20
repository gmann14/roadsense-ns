export type MunicipalityConfig = {
  slug: string;
  name: string;
  aliases: string[];
  bbox: [minLng: number, minLat: number, maxLng: number, maxLat: number];
  center: [lng: number, lat: number];
  defaultZoom: number;
};

export const municipalityManifest: MunicipalityConfig[] = [
  {
    slug: "halifax",
    name: "Halifax",
    aliases: ["Halifax Regional Municipality", "HRM", "Halifax NS"],
    bbox: [-64.05, 44.38, -63.1, 45.05],
    center: [-63.5752, 44.6488],
    defaultZoom: 10.6,
  },
  {
    slug: "cape-breton-regional-municipality",
    name: "Cape Breton Regional Municipality",
    aliases: ["CBRM", "Cape Breton"],
    bbox: [-60.72, 46.02, -59.73, 46.45],
    center: [-60.1942, 46.1368],
    defaultZoom: 10.1,
  },
  {
    slug: "truro",
    name: "Truro",
    aliases: ["Town of Truro"],
    bbox: [-63.35, 45.32, -63.18, 45.4],
    center: [-63.2871, 45.3656],
    defaultZoom: 12.4,
  },
  {
    slug: "kentville",
    name: "Kentville",
    aliases: ["Town of Kentville"],
    bbox: [-64.58, 45.04, -64.45, 45.12],
    center: [-64.496, 45.0772],
    defaultZoom: 12.8,
  },
];

export function getMunicipalityBySlug(slug: string): MunicipalityConfig | null {
  return municipalityManifest.find((entry) => entry.slug === slug) ?? null;
}

export function getMunicipalityByName(name: string): MunicipalityConfig | null {
  const normalized = normalizeMunicipalityQuery(name);
  return (
    municipalityManifest.find((entry) =>
      [entry.name, ...entry.aliases].some((candidate) => normalizeMunicipalityQuery(candidate) === normalized),
    ) ?? null
  );
}

export type MunicipalitySearchResult = {
  municipality: MunicipalityConfig;
  score: number;
  matchedOn: string;
};

export function searchMunicipalities(query: string): MunicipalitySearchResult[] {
  const normalizedQuery = normalizeMunicipalityQuery(query);
  if (!normalizedQuery) {
    return [];
  }

  return municipalityManifest
    .map((municipality) => {
      const candidates = [municipality.name, ...municipality.aliases];
      let bestScore = -1;
      let matchedOn = municipality.name;

      for (const candidate of candidates) {
        const normalizedCandidate = normalizeMunicipalityQuery(candidate);
        let score = -1;

        if (normalizedCandidate === normalizedQuery) {
          score = 100;
        } else if (normalizedCandidate.startsWith(normalizedQuery)) {
          score = 80;
        } else if (normalizedCandidate.includes(normalizedQuery)) {
          score = 60;
        }

        if (score > bestScore) {
          bestScore = score;
          matchedOn = candidate;
        }
      }

      return bestScore >= 0
        ? {
            municipality,
            score: bestScore,
            matchedOn,
          }
        : null;
    })
    .filter((result): result is MunicipalitySearchResult => result !== null)
    .sort((left, right) => right.score - left.score || left.municipality.name.localeCompare(right.municipality.name));
}

export function normalizeMunicipalityQuery(value: string): string {
  return value.trim().toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ");
}
