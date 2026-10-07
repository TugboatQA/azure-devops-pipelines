#!/usr/bin/env bash
# Refreshes every unlocked base preview in TUGBOAT_REPO. Tugboat rebuilds the
# child previews of each base preview after its refresh finishes.

# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"

base_previews=$(list_previews | jq --raw-output '.[] | select(.anchor == true and .locked != true) | .id')
failures=0

if [[ -z "${base_previews}" ]]; then
    echo "No unlocked base previews in repository ${TUGBOAT_REPO}"
    exit 0
fi

for preview_id in ${base_previews}; do
    echo "Refreshing base preview ${preview_id} and rebuilding its children"
    if ! tugboat_api POST "/previews/${preview_id}/refresh" '{"children": true}' >/dev/null; then
        warn "Could not refresh base preview ${preview_id}"
        failures=$((failures + 1))
    fi
done

((failures == 0))
