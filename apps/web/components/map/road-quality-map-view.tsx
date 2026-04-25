"use client";

import { useEffect, useEffectEvent, useRef, useState } from "react";
import type * as mapboxgl from "mapbox-gl";

import {
  type Bbox,
  getCoverageTileUrlTemplate,
  getMapboxStyleUrl,
  getMapboxToken,
  getPublicReadHeaders,
  getQualityTileUrlTemplate,
} from "@/lib/api/client";
import type { MunicipalityConfig } from "@/lib/municipality-manifest";
import type { MapMode, UrlViewportState } from "@/lib/url-state";

type ViewportCommit = {
  lat: number;
  lng: number;
  z: number;
  bbox: Bbox;
};

type InitialViewport = {
  lat: number;
  lng: number;
  z: number;
};

type RoadQualityMapViewProps = {
  mode: MapMode;
  municipality?: MunicipalityConfig | null;
  routeState: UrlViewportState;
  mapBounds: Bbox | null;
  potholeBounds: Bbox | null;
  onViewportCommit: (viewport: ViewportCommit) => void;
  onSegmentSelect: (segmentId: string) => void;
  onMapReadyChange: (isReady: boolean) => void;
  onMapErrorChange: (message: string | null) => void;
};

const QUALITY_SOURCE_ID = "roadsense-quality";
const COVERAGE_SOURCE_ID = "roadsense-coverage";
const SEGMENT_LAYER_ID = "roadsense-segments";
const SELECTED_SEGMENT_LAYER_ID = "roadsense-segments-selected";
const POTHOLE_LAYER_ID = "roadsense-potholes";
const COVERAGE_LAYER_ID = "roadsense-coverage-segments";
const DATA_BOUNDS_MAX_ZOOM = 13.1;
const POTHOLE_MARKER_MIN_ZOOM = 13.35;
const POTHOLE_MARKER_FOCUS_ZOOM = 13.75;

export function RoadQualityMapView({
  mode,
  municipality,
  routeState,
  mapBounds,
  potholeBounds,
  onViewportCommit,
  onSegmentSelect,
  onMapReadyChange,
  onMapErrorChange,
}: RoadQualityMapViewProps) {
  const mapContainerRef = useRef<HTMLDivElement | null>(null);
  const mapRef = useRef<mapboxgl.Map | null>(null);
  const modeRef = useRef(mode);
  const municipalityRef = useRef(municipality);
  const routeStateRef = useRef(routeState);
  const mapBoundsRef = useRef(mapBounds);
  const potholeBoundsRef = useRef(potholeBounds);
  const [mapSupported, setMapSupported] = useState(true);
  const handleMapReadyChange = useEffectEvent(onMapReadyChange);
  const handleMapErrorChange = useEffectEvent(onMapErrorChange);
  const handleSegmentSelect = useEffectEvent(onSegmentSelect);
  const handleViewportCommit = useEffectEvent(onViewportCommit);

  useEffect(() => {
    modeRef.current = mode;
  }, [mode]);

  useEffect(() => {
    municipalityRef.current = municipality;
  }, [municipality]);

  useEffect(() => {
    routeStateRef.current = routeState;
  }, [routeState]);

  useEffect(() => {
    mapBoundsRef.current = mapBounds;
  }, [mapBounds]);

  useEffect(() => {
    potholeBoundsRef.current = potholeBounds;
  }, [potholeBounds]);

  useEffect(() => {
    const mapboxToken = getMapboxToken();
    if (!mapboxToken) {
      setMapSupported(false);
      handleMapReadyChange(false);
      handleMapErrorChange("Mapbox is not configured yet for this environment.");
      return;
    }

    if (!mapContainerRef.current || mapRef.current) {
      return;
    }

    let cancelled = false;
    const initialBounds = resolveInitialBounds(
      routeStateRef.current,
      municipalityRef.current,
      mapBoundsRef.current,
    );
    const initialViewport = resolveInitialViewport(
      routeStateRef.current,
      municipalityRef.current,
      mapBoundsRef.current,
    );
    let mapInstance: mapboxgl.Map | null = null;

    void import("mapbox-gl").then(({ default: mapboxglRuntime }) => {
      if (cancelled || !mapContainerRef.current || mapRef.current) {
        return;
      }

      mapboxglRuntime.accessToken = mapboxToken;
      const sourceBaseUrl = getQualityTileUrlTemplate().replace("/tiles/{z}/{x}/{y}.mvt", "");

      const mapOptions: mapboxgl.MapOptions = {
        container: mapContainerRef.current,
        style: getMapboxStyleUrl(),
        center: [initialViewport.lng, initialViewport.lat],
        zoom: initialViewport.z,
        attributionControl: true,
        antialias: true,
        transformRequest(url) {
          if (!url.startsWith(sourceBaseUrl)) {
            return { url };
          }

          return {
            url,
            headers: getPublicReadHeaders() as Record<string, string>,
          };
        },
      };

      if (initialBounds) {
        mapOptions.bounds = bboxToLngLatBoundsLike(initialBounds);
        mapOptions.fitBoundsOptions = {
          padding: 92,
          maxZoom: DATA_BOUNDS_MAX_ZOOM,
        };
      }

      const map = new mapboxglRuntime.Map(mapOptions);

      mapRef.current = map;
      mapInstance = map;

      map.addControl(new mapboxglRuntime.NavigationControl({ visualizePitch: false }), "top-right");

      map.on("load", () => {
        handleMapReadyChange(true);
        handleMapErrorChange(null);

        if (!map.getSource(QUALITY_SOURCE_ID)) {
          map.addSource(QUALITY_SOURCE_ID, {
            type: "vector",
            tiles: [getQualityTileUrlTemplate()],
            minzoom: 5,
            maxzoom: 15,
          });
        }

        if (!map.getSource(COVERAGE_SOURCE_ID)) {
          map.addSource(COVERAGE_SOURCE_ID, {
            type: "vector",
            tiles: [getCoverageTileUrlTemplate()],
            minzoom: 5,
            maxzoom: 15,
          });
        }

        if (!map.getLayer(SEGMENT_LAYER_ID)) {
          map.addLayer({
            id: SEGMENT_LAYER_ID,
            type: "line",
            source: QUALITY_SOURCE_ID,
            "source-layer": "segment_aggregates",
            paint: {
              "line-color": [
                "match",
                ["get", "category"],
                "smooth",
                "#27936d",
                "fair",
                "#d8a23b",
                "rough",
                "#d66c35",
                "very_rough",
                "#c53d45",
                "unpaved",
                "#7a6754",
                "#97a6ad",
              ],
              "line-width": ["interpolate", ["linear"], ["zoom"], 6, 2.2, 11, 4.2, 14, 7.2],
              "line-opacity": [
                "match",
                ["get", "confidence"],
                "low",
                0.4,
                "medium",
                0.72,
                0.96,
              ],
            },
          });
        }

        if (!map.getLayer(SELECTED_SEGMENT_LAYER_ID)) {
          map.addLayer({
            id: SELECTED_SEGMENT_LAYER_ID,
            type: "line",
            source: QUALITY_SOURCE_ID,
            "source-layer": "segment_aggregates",
            filter: ["==", ["get", "id"], ""],
            paint: {
              "line-color": "#142830",
              "line-width": ["interpolate", ["linear"], ["zoom"], 6, 4.5, 11, 7, 14, 11],
              "line-opacity": 1,
            },
          });
        }

        map.setFilter(SELECTED_SEGMENT_LAYER_ID, ["==", ["get", "id"], routeStateRef.current.segment ?? ""]);

        if (!map.getLayer(POTHOLE_LAYER_ID)) {
          map.addLayer({
            id: POTHOLE_LAYER_ID,
            type: "circle",
            source: QUALITY_SOURCE_ID,
            "source-layer": "potholes",
            paint: {
              "circle-radius": ["interpolate", ["linear"], ["zoom"], 6, 3, 12, 6, 15, 8],
              "circle-color": "#c53d45",
              "circle-stroke-color": "#fffaf1",
              "circle-stroke-width": 1.5,
              "circle-opacity": 0.95,
            },
          });
        }

        if (!map.getLayer(COVERAGE_LAYER_ID)) {
          map.addLayer({
            id: COVERAGE_LAYER_ID,
            type: "line",
            source: COVERAGE_SOURCE_ID,
            "source-layer": "segment_coverage",
            layout: {
              visibility: "none",
            },
            paint: {
              "line-color": [
                "match",
                ["get", "coverage_level"],
                "none",
                "#d9ddd6",
                "emerging",
                "#8cb4c1",
                "published",
                "#2f7f94",
                "strong",
                "#134d5e",
                "#d9ddd6",
              ],
              "line-width": ["interpolate", ["linear"], ["zoom"], 6, 2.2, 11, 4.2, 14, 7.2],
              "line-opacity": 0.95,
            },
          });
        }

        applyLayerVisibility(map, modeRef.current);

        map.on("mouseenter", SEGMENT_LAYER_ID, () => {
          map.getCanvas().style.cursor = "pointer";
        });

        map.on("mouseleave", SEGMENT_LAYER_ID, () => {
          map.getCanvas().style.cursor = "";
        });

        map.on("click", SEGMENT_LAYER_ID, (event) => {
          const feature = event.features?.[0];
          const segmentId = feature?.properties?.id;
          if (typeof segmentId === "string" && segmentId.length > 0) {
            handleSegmentSelect(segmentId);
          }
        });

        const commitViewport = () => {
          const bounds = map.getBounds();
          if (!bounds) {
            return;
          }
          const center = map.getCenter();
          handleViewportCommit({
            lat: center.lat,
            lng: center.lng,
            z: map.getZoom(),
            bbox: {
              minLng: bounds.getWest(),
              minLat: bounds.getSouth(),
              maxLng: bounds.getEast(),
              maxLat: bounds.getNorth(),
            },
          });
        };

        if (initialBounds) {
          map.once("idle", commitViewport);
        } else {
          commitViewport();
        }

        map.on("moveend", () => {
          commitViewport();
        });
      });

      map.on("error", (event) => {
        if (event.error?.message) {
          handleMapErrorChange("Road data is temporarily unavailable. Try again shortly.");
        }
      });
    });

    return () => {
      cancelled = true;
      handleMapReadyChange(false);
      mapInstance?.remove();
      mapRef.current = null;
    };
    // Mapbox owns this DOM subtree. Route/mode updates are handled by the smaller effects below.
  }, []);

  useEffect(() => {
    const map = mapRef.current;
    if (!map || !map.isStyleLoaded() || !map.getLayer(SELECTED_SEGMENT_LAYER_ID)) {
      return;
    }

    const segmentId = routeState.segment ?? "";
    map.setFilter(SELECTED_SEGMENT_LAYER_ID, ["==", ["get", "id"], segmentId]);
  }, [routeState.segment]);

  useEffect(() => {
    const map = mapRef.current;
    if (
      !map ||
      routeState.lat === null ||
      routeState.lng === null ||
      routeState.z === null
    ) {
      return;
    }

    const center = map.getCenter();
    const zoom = map.getZoom();
    const isAlreadySynced =
      Math.abs(center.lat - routeState.lat) < 0.00002 &&
      Math.abs(center.lng - routeState.lng) < 0.00002 &&
      Math.abs(zoom - routeState.z) < 0.02;
    if (isAlreadySynced) {
      return;
    }

    map.easeTo({
      center: [routeState.lng, routeState.lat],
      zoom: routeState.z,
      duration: 450,
      essential: true,
    });
  }, [routeState.lat, routeState.lng, routeState.z]);

  useEffect(() => {
    const map = mapRef.current;
    if (!map) {
      return;
    }

    applyLayerVisibility(map, mode);

    if (mode === "potholes" && map.getZoom() < POTHOLE_MARKER_MIN_ZOOM) {
      const potholeBounds = potholeBoundsRef.current;
      const currentBounds = map.getBounds();
      if (potholeBounds && currentBounds && !mapBoundsOverlap(currentBounds, potholeBounds)) {
        map.fitBounds(bboxToLngLatBoundsLike(potholeBounds), {
          padding: 120,
          maxZoom: POTHOLE_MARKER_FOCUS_ZOOM,
          duration: 500,
          essential: true,
        });
        return;
      }

      map.easeTo({
        zoom: POTHOLE_MARKER_FOCUS_ZOOM,
        duration: 450,
        essential: true,
      });
    }
  }, [mode]);

  return (
    <div className="map-canvas-shell">
      <div ref={mapContainerRef} className="map-canvas" />
      {!mapSupported ? (
        <div className="map-overlay-banner">
          <strong>Mapbox token missing.</strong>
          Add <code>NEXT_PUBLIC_MAPBOX_TOKEN</code> to render the live public map.
        </div>
      ) : null}
      {mode === "potholes" ? (
        <div className="map-overlay-banner" style={{ bottom: 24, top: "auto" }}>
          <strong>Potholes mode is live.</strong>
          This view isolates active pothole markers and keeps the side panel focused on recent community-confirmed
          impacts.
        </div>
      ) : null}
      {mode === "coverage" ? (
        <div className="map-overlay-banner" style={{ bottom: 24, top: "auto" }}>
          <strong>Coverage mode is live.</strong>
          This source answers where RoadSense has enough community data to publish reliable conditions.
        </div>
      ) : null}
    </div>
  );
}

function applyLayerVisibility(map: mapboxgl.Map, mode: MapMode) {
  const visibleLayerIds = new Set<string>();
  if (mode === "quality") {
    visibleLayerIds.add(SEGMENT_LAYER_ID);
    visibleLayerIds.add(SELECTED_SEGMENT_LAYER_ID);
    visibleLayerIds.add(POTHOLE_LAYER_ID);
  } else if (mode === "potholes") {
    visibleLayerIds.add(POTHOLE_LAYER_ID);
  } else if (mode === "coverage") {
    visibleLayerIds.add(COVERAGE_LAYER_ID);
  }

  for (const layerId of [
    SEGMENT_LAYER_ID,
    SELECTED_SEGMENT_LAYER_ID,
    POTHOLE_LAYER_ID,
    COVERAGE_LAYER_ID,
  ]) {
    if (map.getLayer(layerId)) {
      map.setLayoutProperty(layerId, "visibility", visibleLayerIds.has(layerId) ? "visible" : "none");
    }
  }
}

function resolveInitialViewport(
  routeState: UrlViewportState,
  municipality?: MunicipalityConfig | null,
  mapBounds?: Bbox | null,
): InitialViewport {
  if (
    routeState.lat !== null &&
    routeState.lng !== null &&
    routeState.z !== null
  ) {
    return {
      lat: routeState.lat,
      lng: routeState.lng,
      z: routeState.z,
    };
  }

  if (municipality) {
    return {
      lng: municipality.center[0],
      lat: municipality.center[1],
      z: municipality.defaultZoom,
    };
  }

  if (mapBounds) {
    return {
      lat: (mapBounds.minLat + mapBounds.maxLat) / 2,
      lng: (mapBounds.minLng + mapBounds.maxLng) / 2,
      z: DATA_BOUNDS_MAX_ZOOM,
    };
  }

  return {
    lat: 44.68199,
    lng: -63.74431,
    z: 7.2,
  };
}

function resolveInitialBounds(
  routeState: UrlViewportState,
  municipality?: MunicipalityConfig | null,
  mapBounds?: Bbox | null,
): Bbox | null {
  if (
    routeState.lat !== null &&
    routeState.lng !== null &&
    routeState.z !== null
  ) {
    return null;
  }

  if (municipality) {
    return null;
  }

  return mapBounds ?? null;
}

function bboxToLngLatBoundsLike(bbox: Bbox): mapboxgl.LngLatBoundsLike {
  return [
    [bbox.minLng, bbox.minLat],
    [bbox.maxLng, bbox.maxLat],
  ];
}

function mapBoundsOverlap(bounds: mapboxgl.LngLatBounds, bbox: Bbox): boolean {
  return (
    bounds.getWest() <= bbox.maxLng &&
    bounds.getEast() >= bbox.minLng &&
    bounds.getSouth() <= bbox.maxLat &&
    bounds.getNorth() >= bbox.minLat
  );
}
