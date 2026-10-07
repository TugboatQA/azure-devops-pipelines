#!/usr/bin/env bash
# Handles a pull request event from an Azure DevOps service hook.
#
# Usage:
#   pr-event.sh PR_ID
#
# The script ignores the rest of the webhook payload, because the incoming
# webhook URL accepts requests without authentication. It reads the pull
# request from the Azure DevOps API instead:
#   - Active: create or rebuild the preview, post the Tugboat, Visual Diffs,
#     and Lighthouse status checks, and post or update the preview links
#     comment.
#   - Completed or abandoned: delete the preview.

# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"

# How long to wait for Visual Diffs and Lighthouse reports after the preview
# build ends.
REPORT_TIMEOUT_SECONDS="${REPORT_TIMEOUT_SECONDS:-1200}"

pr_id="${1:-}"
# The ID comes from the unauthenticated webhook payload. Do not print it.
if [[ ! "${pr_id}" =~ ^[0-9]+$ ]]; then
    echo "##vso[task.logissue type=error]Invalid pull request ID"
    exit 1
fi

pr=$(azure_api GET "/pullRequests/${pr_id}")
status=$(jq --raw-output '.status' <<<"${pr}")
previews=$(list_previews)
preview_id=$(find_pr_preview "${previews}" "${pr_id}")

if [[ "${status}" != "active" ]]; then
    if [[ -z "${preview_id}" ]]; then
        echo "PR #${pr_id} is ${status} and has no preview"
    elif preview_locked "${previews}" "${preview_id}"; then
        echo "PR #${pr_id} is ${status}: preview ${preview_id} is locked, skipping"
    else
        echo "PR #${pr_id} is ${status}: deleting preview ${preview_id}"
        tugboat_api DELETE "/previews/${preview_id}" >/dev/null
    fi
    exit 0
fi

run_url="${SYSTEM_COLLECTIONURI}${SYSTEM_TEAMPROJECTID}/_build/results?buildId=${BUILD_BUILDID}"
post_status "${pr_id}" "${STATUS_BUILD}" pending "Building the Tugboat preview" "${run_url}"
post_status "${pr_id}" "${STATUS_VISUALDIFFS}" pending "Waiting for the Tugboat preview" "${run_url}"
post_status "${pr_id}" "${STATUS_LIGHTHOUSE}" pending "Waiting for the Tugboat preview" "${run_url}"

if [[ -z "${preview_id}" ]]; then
    source_branch=$(jq --raw-output '.sourceRefName | ltrimstr("refs/heads/")' <<<"${pr}")
    target_branch=$(jq --raw-output '.targetRefName | ltrimstr("refs/heads/")' <<<"${pr}")
    name="${PREVIEW_NAME_PREFIX}${pr_id}: $(jq --raw-output '.title' <<<"${pr}")"

    # Build from the target branch's base preview, so Visual Diffs have
    # something to compare against. Tugboat cannot look up a pull request's
    # target branch for a plain Git repository, so pass the base preview ID.
    base_id=$(jq --raw-output --arg ref "${target_branch}" \
        'first(.[] | select(.anchor == true and .ref == $ref) | .id) // "none"' <<<"${previews}")

    echo "Creating a preview of ${source_branch} (base: ${base_id})"
    body=$(jq --null-input \
        --arg repo "${TUGBOAT_REPO}" --arg ref "${source_branch}" \
        --arg name "${name}" --arg base "${base_id}" \
        '{repo: $repo, ref: $ref, type: "branch", name: $name, base: $base}')
    job=$(tugboat_api POST /previews "${body}")
else
    echo "Rebuilding preview ${preview_id}"
    job=$(tugboat_api POST "/previews/${preview_id}/rebuild" '{"force": true}')
fi

job_id=$(jq --raw-output '.id' <<<"${job}")
preview_id=$(jq --raw-output '.object' <<<"${job}")
preview_url="${TUGBOAT_DASHBOARD}/${preview_id}"
echo "Waiting for job ${job_id}: ${preview_url}"
set_comment "${pr_id}" "${COMMENT_HEADER} is building a new preview for this pull request..."$'\n\n'"Dashboard:"$'\n'"- ${preview_url}" \
    || warn "Could not update the pull request comment"

job=$(wait_for_job "${job_id}")
if [[ "$(jq --raw-output '.result' <<<"${job}")" != "success" ]]; then
    message=$(jq --raw-output '.message // "The Tugboat preview build failed" | gsub("[\\r\\n]+"; " ")' <<<"${job}")
    post_status "${pr_id}" "${STATUS_BUILD}" failed "${message:0:200}" "${preview_url}"
    post_status "${pr_id}" "${STATUS_VISUALDIFFS}" error "Not run: the Tugboat preview failed to build" "${preview_url}"
    post_status "${pr_id}" "${STATUS_LIGHTHOUSE}" error "Not run: the Tugboat preview failed to build" "${preview_url}"
    set_comment "${pr_id}" "${COMMENT_HEADER} failed to build the preview for this pull request."$'\n\n'"Dashboard:"$'\n'"- ${preview_url}" \
        || warn "Could not update the pull request comment"
    echo "##vso[task.logissue type=error]${message}"
    exit 1
fi
post_status "${pr_id}" "${STATUS_BUILD}" succeeded "The Tugboat preview is ready" "${preview_url}"

preview=$(tugboat_api GET "/previews/${preview_id}")
if ! links=$(comment_links_body "${preview}") || ! set_comment "${pr_id}" "${links}" post; then
    warn "Could not post the pull request comment"
fi

# Tugboat renders Visual Diffs and Lighthouse reports after the build job ends.
# Wait until every report from this build is finished, then post the results.
deadline=$((SECONDS + REPORT_TIMEOUT_SECONDS))
# Tugboat creates the report records shortly after the job ends, so do not
# treat "no reports" as final until this many seconds have passed.
empty_deadline=$((SECONDS + 180))
while true; do
    reports=$(preview_reports "${preview_id}")
    statuses=$(report_statuses "${preview}" "${reports}")
    found=$(jq '(.visualdiffs + .lighthouse) | length' <<<"${reports}")

    if jq --exit-status 'all(.[]; .state != "pending")' <<<"${statuses}" >/dev/null \
        && ((found > 0 || SECONDS > empty_deadline)); then
        break
    fi
    if ((SECONDS > deadline)); then
        statuses=$(jq 'map(if .state == "pending" then .state = "error" | .description = "Timed out: \(.description)" else . end)' <<<"${statuses}")
        break
    fi
    sleep 30
done

post_report_statuses "${pr_id}" "${statuses}"
