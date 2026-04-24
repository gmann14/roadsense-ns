#!/usr/bin/env bash

roadsense_load_region_config() {
    local region_key="${1:-nova-scotia}"

    case "${region_key}" in
        alberta)
            export ROAD_SENSE_REGION_KEY="alberta"
            export ROAD_SENSE_REGION_NAME="Alberta"
            export ROAD_SENSE_REGION_PRUID="48"
            export ROAD_SENSE_GEOFABRIK_SLUG="alberta"
            ;;
        british-columbia)
            export ROAD_SENSE_REGION_KEY="british-columbia"
            export ROAD_SENSE_REGION_NAME="British Columbia"
            export ROAD_SENSE_REGION_PRUID="59"
            export ROAD_SENSE_GEOFABRIK_SLUG="british-columbia"
            ;;
        manitoba)
            export ROAD_SENSE_REGION_KEY="manitoba"
            export ROAD_SENSE_REGION_NAME="Manitoba"
            export ROAD_SENSE_REGION_PRUID="46"
            export ROAD_SENSE_GEOFABRIK_SLUG="manitoba"
            ;;
        new-brunswick)
            export ROAD_SENSE_REGION_KEY="new-brunswick"
            export ROAD_SENSE_REGION_NAME="New Brunswick"
            export ROAD_SENSE_REGION_PRUID="13"
            export ROAD_SENSE_GEOFABRIK_SLUG="new-brunswick"
            ;;
        newfoundland-and-labrador)
            export ROAD_SENSE_REGION_KEY="newfoundland-and-labrador"
            export ROAD_SENSE_REGION_NAME="Newfoundland and Labrador"
            export ROAD_SENSE_REGION_PRUID="10"
            export ROAD_SENSE_GEOFABRIK_SLUG="newfoundland-and-labrador"
            ;;
        northwest-territories)
            export ROAD_SENSE_REGION_KEY="northwest-territories"
            export ROAD_SENSE_REGION_NAME="Northwest Territories"
            export ROAD_SENSE_REGION_PRUID="61"
            export ROAD_SENSE_GEOFABRIK_SLUG="northwest-territories"
            ;;
        nova-scotia)
            export ROAD_SENSE_REGION_KEY="nova-scotia"
            export ROAD_SENSE_REGION_NAME="Nova Scotia"
            export ROAD_SENSE_REGION_PRUID="12"
            export ROAD_SENSE_GEOFABRIK_SLUG="nova-scotia"
            ;;
        nunavut)
            export ROAD_SENSE_REGION_KEY="nunavut"
            export ROAD_SENSE_REGION_NAME="Nunavut"
            export ROAD_SENSE_REGION_PRUID="62"
            export ROAD_SENSE_GEOFABRIK_SLUG="nunavut"
            ;;
        ontario)
            export ROAD_SENSE_REGION_KEY="ontario"
            export ROAD_SENSE_REGION_NAME="Ontario"
            export ROAD_SENSE_REGION_PRUID="35"
            export ROAD_SENSE_GEOFABRIK_SLUG="ontario"
            ;;
        prince-edward-island)
            export ROAD_SENSE_REGION_KEY="prince-edward-island"
            export ROAD_SENSE_REGION_NAME="Prince Edward Island"
            export ROAD_SENSE_REGION_PRUID="11"
            export ROAD_SENSE_GEOFABRIK_SLUG="prince-edward-island"
            ;;
        quebec)
            export ROAD_SENSE_REGION_KEY="quebec"
            export ROAD_SENSE_REGION_NAME="Quebec"
            export ROAD_SENSE_REGION_PRUID="24"
            export ROAD_SENSE_GEOFABRIK_SLUG="quebec"
            ;;
        saskatchewan)
            export ROAD_SENSE_REGION_KEY="saskatchewan"
            export ROAD_SENSE_REGION_NAME="Saskatchewan"
            export ROAD_SENSE_REGION_PRUID="47"
            export ROAD_SENSE_GEOFABRIK_SLUG="saskatchewan"
            ;;
        yukon)
            export ROAD_SENSE_REGION_KEY="yukon"
            export ROAD_SENSE_REGION_NAME="Yukon"
            export ROAD_SENSE_REGION_PRUID="60"
            export ROAD_SENSE_GEOFABRIK_SLUG="yukon"
            ;;
        *)
            echo "Unsupported REGION_KEY: ${region_key}" >&2
            echo "Supported REGION_KEY values:" >&2
            roadsense_list_supported_regions >&2
            return 1
            ;;
    esac

    export ROAD_SENSE_GEOFABRIK_URL="https://download.geofabrik.de/north-america/canada/${ROAD_SENSE_GEOFABRIK_SLUG}-latest.osm.pbf"
}

roadsense_list_supported_regions() {
    cat <<'EOF'
alberta
british-columbia
manitoba
new-brunswick
newfoundland-and-labrador
northwest-territories
nova-scotia
nunavut
ontario
prince-edward-island
quebec
saskatchewan
yukon
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    roadsense_load_region_config "${1:-nova-scotia}" || exit 1
    cat <<EOF
REGION_KEY=${ROAD_SENSE_REGION_KEY}
REGION_NAME=${ROAD_SENSE_REGION_NAME}
REGION_PRUID=${ROAD_SENSE_REGION_PRUID}
GEOFABRIK_SLUG=${ROAD_SENSE_GEOFABRIK_SLUG}
SNAPSHOT_URL=${ROAD_SENSE_GEOFABRIK_URL}
EOF
fi
