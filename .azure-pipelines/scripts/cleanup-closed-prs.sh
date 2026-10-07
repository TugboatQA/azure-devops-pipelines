#!/usr/bin/env bash
# Deletes every preview these pipelines created whose pull request is no
# longer active. This catches any service hook deliveries that failed.

# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"

previews=$(list_previews)
failures=0

while read -r preview_id pr_id; do
    [[ -z "${preview_id}" ]] && continue
    if ! status=$(azure_api GET "/pullRequests/${pr_id}" | jq --raw-output '.status'); then
        warn "PR #${pr_id}: could not read the pull request"
        failures=$((failures + 1))
        continue
    fi
    if [[ "${status}" == "completed" || "${status}" == "abandoned" ]]; then
        if preview_locked "${previews}" "${preview_id}"; then
            echo "PR #${pr_id} is ${status}: preview ${preview_id} is locked, skipping"
            continue
        fi
        echo "PR #${pr_id} is ${status}: deleting preview ${preview_id}"
        if ! tugboat_api DELETE "/previews/${preview_id}" >/dev/null; then
            warn "PR #${pr_id}: could not delete preview ${preview_id}"
            failures=$((failures + 1))
        fi
    fi
done <<<"$(pr_previews "${previews}")"

((failures == 0))
