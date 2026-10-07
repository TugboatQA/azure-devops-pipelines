#!/usr/bin/env bash
# Deletes every preview these pipelines created whose pull request is no
# longer active. This catches any service hook deliveries that failed.

# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"

while read -r preview_id pr_id; do
    status=$(azure_api GET "/pullRequests/${pr_id}" | jq --raw-output '.status') || status="unknown"
    if [[ "${status}" == "completed" || "${status}" == "abandoned" ]]; then
        echo "PR #${pr_id} is ${status}: deleting preview ${preview_id}"
        tugboat_api DELETE "/previews/${preview_id}" >/dev/null
    fi
done < <(pr_previews "$(list_previews)")
