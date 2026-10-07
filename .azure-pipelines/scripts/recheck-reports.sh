#!/usr/bin/env bash
# Re-evaluates the Visual Diffs and Lighthouse status checks, so a report that
# someone approved in the Tugboat dashboard after it failed now passes.
#
# Usage:
#   recheck-reports.sh [PR_ID]
#
# With PR_ID, rechecks that pull request. With no PR_ID or "all", rechecks
# every active pull request that has a preview. Only posts a status when it
# differs from the status already on the pull request.

# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"

pr_id="${1:-all}"

# Recheck each active pull request in its own process, so a failure for one
# pull request does not stop the others.
if [[ "${pr_id}" == "all" ]]; then
    pr_ids=$(azure_api GET "/pullRequests?searchCriteria.status=active" | jq --raw-output '.value[].pullRequestId')
    failures=0
    for id in ${pr_ids}; do
        if ! bash "$0" "${id}"; then
            warn "PR #${id}: recheck failed"
            failures=$((failures + 1))
        fi
    done
    ((failures == 0))
    exit
fi

if [[ ! "${pr_id}" =~ ^[0-9]+$ ]]; then
    echo "##vso[task.logissue type=error]Invalid pull request ID: '${pr_id}'"
    exit 1
fi

previews=$(list_previews)
preview_id=$(find_pr_preview "${previews}" "${pr_id}")
if [[ -z "${preview_id}" ]]; then
    echo "PR #${pr_id}: no preview"
    exit 0
fi

# While a build is running, the tugboat-pr pipeline posts the statuses.
preview=$(tugboat_api GET "/previews/${preview_id}")
state=$(jq --raw-output '.state' <<<"${preview}")
case "${state}" in
    new | pending | building | rebuilding | refreshing | resetting | failed | cancelled)
        echo "PR #${pr_id}: preview ${preview_id} is ${state}, skipping"
        exit 0
        ;;
esac

echo "PR #${pr_id}: preview ${preview_id}"
reports=$(preview_reports "${preview_id}")
post_report_statuses "${pr_id}" "$(report_statuses "${preview}" "${reports}")"
