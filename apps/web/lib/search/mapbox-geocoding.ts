import { getMapboxToken } from "@/lib/api/client";

const NOVA_SCOTIA_BBOX = [-66.55, 43.2, -59.4, 47.1] as const;

export type PlaceSearchResult = {
  id: string;
  label: string;
  placeName: string;
  center: [lng: number, lat: number];
  zoom: number;
};

type MapboxForwardResponse = {
  features?: Array<{
    id: string;
    properties?: {
      name?: string;
      full_address?: string;
    };
    place_formatted?: string;
    geometry?: {
      coordinates?: [number, number];
    };
    coordinates?: {
      longitude?: number;
      latitude?: number;
    };
    bbox?: [number, number, number, number];
  }>;
};

export async function searchPlaces(query: string, signal?: AbortSignal): Promise<PlaceSearchResult[]> {
  const token = getMapboxToken();
  if (!token || query.trim().length < 3) {
    return [];
  }

  const params = new URLSearchParams({
    q: query.trim(),
    access_token: token,
    country: "CA",
    limit: "5",
    autocomplete: "true",
    bbox: NOVA_SCOTIA_BBOX.join(","),
    types: "place,locality,district,street,address",
  });

  const response = await fetch(`https://api.mapbox.com/search/geocode/v6/forward?${params.toString()}`, {
    signal,
  });
  if (!response.ok) {
    return [];
  }

  const data = (await response.json()) as MapboxForwardResponse;
  return (data.features ?? [])
    .map((feature) => {
      const coordinates =
        feature.geometry?.coordinates ??
        (feature.coordinates?.longitude !== undefined && feature.coordinates?.latitude !== undefined
          ? [feature.coordinates.longitude, feature.coordinates.latitude]
          : null);

      if (!coordinates || coordinates.length !== 2) {
        return null;
      }

      const label = feature.properties?.name ?? feature.place_formatted ?? feature.properties?.full_address;
      if (!label) {
        return null;
      }

      return {
        id: feature.id,
        label,
        placeName: feature.place_formatted ?? feature.properties?.full_address ?? label,
        center: [coordinates[0], coordinates[1]],
        zoom: deriveZoom(feature.bbox),
      } satisfies PlaceSearchResult;
    })
    .filter((result): result is PlaceSearchResult => result !== null);
}

function deriveZoom(bbox: [number, number, number, number] | undefined): number {
  if (!bbox) {
    return 13;
  }

  const lngSpan = Math.abs(bbox[2] - bbox[0]);
  if (lngSpan > 0.8) return 9;
  if (lngSpan > 0.25) return 11;
  if (lngSpan > 0.08) return 12.5;
  return 14.5;
}
