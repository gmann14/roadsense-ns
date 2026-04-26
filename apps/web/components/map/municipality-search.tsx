"use client";

import { usePathname, useRouter } from "next/navigation";
import { startTransition, useDeferredValue, useEffect, useState } from "react";

import { getMunicipalityByName, municipalityManifest, searchMunicipalities } from "@/lib/municipality-manifest";
import { searchPlaces, type PlaceSearchResult } from "@/lib/search/mapbox-geocoding";
import { withUpdatedRouteState, type MapMode } from "@/lib/url-state";

type MunicipalitySearchProps = {
  activeMode: MapMode;
  currentQuery: string | null;
};

type SearchSuggestion =
  | {
      id: string;
      type: "municipality";
      label: string;
      detail: string;
      target: string;
    }
  | {
      id: string;
      type: "place";
      label: string;
      detail: string;
      target: string;
    };

export function MunicipalitySearch({ activeMode, currentQuery }: MunicipalitySearchProps) {
  const pathname = usePathname();
  const router = useRouter();
  const [value, setValue] = useState(currentQuery ?? "");
  const [placeResults, setPlaceResults] = useState<PlaceSearchResult[]>([]);
  const [isLoadingPlaces, setIsLoadingPlaces] = useState(false);
  const deferredValue = useDeferredValue(value);
  const municipalityResults = searchMunicipalities(deferredValue).slice(0, 5);

  useEffect(() => {
    if (municipalityResults.length > 0 || deferredValue.trim().length < 3) {
      setPlaceResults([]);
      setIsLoadingPlaces(false);
      return;
    }

    const controller = new AbortController();
    setIsLoadingPlaces(true);

    void searchPlaces(deferredValue, controller.signal)
      .then((results) => {
        if (!controller.signal.aborted) {
          setPlaceResults(results);
        }
      })
      .catch(() => {
        if (!controller.signal.aborted) {
          setPlaceResults([]);
        }
      })
      .finally(() => {
        if (!controller.signal.aborted) {
          setIsLoadingPlaces(false);
        }
      });

    return () => {
      controller.abort();
    };
  }, [deferredValue, municipalityResults.length]);

  const navigate = (target: string) => {
    startTransition(() => {
      router.push(target, { scroll: false });
    });
  };

  const buildPlaceTarget = (result: PlaceSearchResult) =>
    `${pathname}?${withUpdatedRouteState(new URLSearchParams(), {
      mode: activeMode,
      lat: result.center[1],
      lng: result.center[0],
      z: result.zoom,
      q: result.label,
      segment: null,
    }).toString()}`;

  const navigateToSelection = () => {
    const municipality = getMunicipalityByName(value.trim());

    if (municipality) {
      const params = withUpdatedRouteState(new URLSearchParams(), {
        mode: activeMode,
        q: municipality.name,
      });
      navigate(`/municipality/${municipality.slug}?${params.toString()}`);
      return;
    }

    const firstPlace = placeResults[0];
    if (firstPlace) {
      navigate(buildPlaceTarget(firstPlace));
      return;
    }

    if (value.trim().length === 0 && pathname !== "/") {
      const params = withUpdatedRouteState(new URLSearchParams(), {
        mode: activeMode,
      });
      navigate(`/?${params.toString()}`);
    }
  };

  const suggestions: SearchSuggestion[] = [
    ...municipalityResults.map((result) => ({
      id: result.municipality.slug,
      type: "municipality" as const,
      label: result.municipality.name,
      detail:
        result.matchedOn === result.municipality.name
          ? "Municipality"
          : `Matched via ${result.matchedOn}`,
      target: `/municipality/${result.municipality.slug}?${withUpdatedRouteState(new URLSearchParams(), {
        mode: activeMode,
        q: result.municipality.name,
      }).toString()}`,
    })),
    ...placeResults.map((result) => ({
      id: result.id,
      type: "place" as const,
      label: result.label,
      detail: result.placeName,
      target: buildPlaceTarget(result),
    })),
  ].slice(0, 6);
  const trimmedValue = value.trim();
  const showNoResults = trimmedValue.length >= 3 && !isLoadingPlaces && suggestions.length === 0;

  return (
    <form
      className="municipality-search"
      onSubmit={(event) => {
        event.preventDefault();
        navigateToSelection();
      }}
    >
      <label style={{ display: "grid", gap: 4 }}>
        <span className="eyebrow">Search municipalities or places</span>
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          <input
            className="search-input"
            list="municipality-options"
            placeholder="Halifax, Truro, Lunenburg…"
            aria-label="Search municipalities or places"
            value={value}
            onChange={(event) => setValue(event.target.value)}
          />
          {trimmedValue.length > 0 ? (
            <button
              type="button"
              className="secondary-button"
              onClick={() => {
                setValue("");
                setPlaceResults([]);
                setIsLoadingPlaces(false);
              }}
            >
              Clear
            </button>
          ) : null}
          <button type="submit" className="secondary-button">
            Go
          </button>
        </div>
      </label>
      {suggestions.length > 0 ? (
        <div className="search-results" role="listbox" aria-label="Search suggestions">
          {suggestions.map((suggestion) => (
            <button
              key={suggestion.id}
              type="button"
              className="search-result-button"
              onClick={() => navigate(suggestion.target)}
            >
              <strong>{suggestion.label}</strong>
              <span className="lede" style={{ margin: 0, fontSize: "0.92rem" }}>
                {suggestion.type === "municipality" ? suggestion.detail : `Place · ${suggestion.detail}`}
              </span>
            </button>
          ))}
        </div>
      ) : isLoadingPlaces ? (
        <div className="search-results">
          <div className="search-result-button" aria-live="polite">
            <strong>Searching Nova Scotia places…</strong>
            <span className="lede" style={{ margin: 0, fontSize: "0.92rem" }}>
              Falling back to Mapbox geocoding because there was no municipality match.
            </span>
          </div>
        </div>
      ) : showNoResults ? (
        <div className="search-results">
          <div className="search-result-button" aria-live="polite">
            <strong>No municipality or place match for “{trimmedValue}”.</strong>
            <span className="lede" style={{ margin: 0, fontSize: "0.92rem" }}>
              Try a municipality name first, or clear the query and zoom the map before searching again.
            </span>
          </div>
        </div>
      ) : null}
      <datalist id="municipality-options">
        {municipalityManifest.map((municipality) => (
          <option key={municipality.slug} value={municipality.name} />
        ))}
      </datalist>
    </form>
  );
}
