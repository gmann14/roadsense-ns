export type MunicipalityConfig = {
  slug: string;
  name: string;
  bbox: [minLng: number, minLat: number, maxLng: number, maxLat: number];
  center: [lng: number, lat: number];
  defaultZoom: number;
};

export const municipalityManifest: MunicipalityConfig[] = [
  {
    slug: "halifax",
    name: "Halifax",
    bbox: [-64.05, 44.38, -63.1, 45.05],
    center: [-63.5752, 44.6488],
    defaultZoom: 10.6,
  },
  {
    slug: "cape-breton-regional-municipality",
    name: "Cape Breton Regional Municipality",
    bbox: [-60.72, 46.02, -59.73, 46.45],
    center: [-60.1942, 46.1368],
    defaultZoom: 10.1,
  },
  {
    slug: "truro",
    name: "Truro",
    bbox: [-63.35, 45.32, -63.18, 45.4],
    center: [-63.2871, 45.3656],
    defaultZoom: 12.4,
  },
  {
    slug: "kentville",
    name: "Kentville",
    bbox: [-64.58, 45.04, -64.45, 45.12],
    center: [-64.496, 45.0772],
    defaultZoom: 12.8,
  },
];

export function getMunicipalityBySlug(slug: string): MunicipalityConfig | null {
  return municipalityManifest.find((entry) => entry.slug === slug) ?? null;
}

export function getMunicipalityByName(name: string): MunicipalityConfig | null {
  return municipalityManifest.find((entry) => entry.name === name) ?? null;
}
