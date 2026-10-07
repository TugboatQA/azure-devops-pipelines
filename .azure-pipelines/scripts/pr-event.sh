#!/usr/bin/env bash
# Handles a pull request event from an Azure DevOps service hook.
#
# Usage:
#   pr-event.sh PR_ID
#
# The script ignores the rest of the webhook payload, because the incoming
# webhook URL accepts requests without authentication. It reads the pull
# request from the Azure DevOps API instead:
#   - Active: create or rebuild the preview, then post the Tugboat, Visual
#     Diffs, and Lighthouse status checks.
#   - Completed or abandoned: delete the preview.

# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"

# How long to wait for Visual Diffs and Lighthouse reports after the preview
# build ends.
REPORT_TIMEOUT_SECONDS="${REPORT_TIMEOUT_SECONDS:-1200}"

pr_id="${1:-}"
if [[ ! "${pr_id}" =~ ^[0-9]+$ ]]; then
    echo "##vso[task.logissue type=error]Invalid pull request ID: '${pr_id}'"
    exit 1
fi

pr=$(azure_api GET "/pullRequests/${pr_id}")
status=$(jq --raw-output '.status' <<<"${pr}")
previews=$(list_previews)
preview_id=$(pr_previews "${previews}" | awk -v pr="${pr_id}" '$2 == pr && !found { print $1; found = 1 }')

if [[ "${status}" != "active" ]]; then
    if [[ -n "${preview_id}" ]]; then
        echo "PR #${pr_id} is ${status}: deleting preview ${preview_id}"
        tugboat_api DELETE "/previews/${preview_id}" >/dev/null
    else
        echo "PR #${pr_id} is ${status} and has no preview"
    fi
    exit 0
fi

run_url="${SYSTEM_COLLECTIONURI}${SYSTEM_TEAMPROJECTID}/_build/results?buildId=${BUILD_BUILDID}"
post_status "${pr_id}" "${STATUS_BUILD}" pending "Building the Tugboat preview" "${run_url}"

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

job=$(wait_for_job "${job_id}")
if [[ "$(jq --raw-output '.result' <<<"${job}")" != "success" ]]; then
    message=$(jq --raw-output '.message // "The Tugboat preview build failed"' <<<"${job}")
    post_status "${pr_id}" "${STATUS_BUILD}" failed "${message:0:200}" "${preview_url}"
    echo "##vso[task.logissue type=error]${message}"
    exit 1
fi
post_status "${pr_id}" "${STATUS_BUILD}" succeeded "The Tugboat preview is ready" "${preview_url}"

# Tugboat renders Visual Diffs and Lighthouse reports after the build job ends.
# A report counts as finished when it has a result or an error and was updated
# after this job started; older reports are from the previous build.
started=$(jq --raw-output '.startedAt // .createdAt' <<<"${job}")
post_status "${pr_id}" "${STATUS_VISUALDIFFS}" pending "Rendering Visual Diffs" "${preview_url}/visualdiffs"
post_status "${pr_id}" "${STATUS_LIGHTHOUSE}" pending "Generating Lighthouse reports" "${preview_url}"

deadline=$((SECONDS + REPORT_TIMEOUT_SECONDS))
# Tugboat creates report records shortly after the job ends, so do not treat
# "no reports" as final until this many seconds have passed.
empty_deadline=$((SECONDS + 180))
while true; do
    visualdiffs="[]"
    lighthouse="[]"
    for service_id in $(tugboat_api GET "/previews/${preview_id}/services" | jq --raw-output '.[].id'); do
        lighthouse=$(jq --slurp 'add' <<<"${lighthouse} $(tugboat_api GET "/services/${service_id}/lighthouse")")
        for screenshot_id in $(tugboat_api GET "/services/${service_id}/screenshots" | jq --raw-output '.[].id'); do
            visualdiffs=$(jq --slurp 'add' <<<"${visualdiffs} $(tugboat_api GET "/screenshots/${screenshot_id}/visualdiffs")")
        done
    done

    vd_done=$(jq --arg started "${started}" 'all(.[]; .updatedAt >= $started and (.size or .error))' <<<"${visualdiffs}")
    lh_done=$(jq --arg started "${started}" 'all(.[]; .updatedAt >= $started and (.summary or .error))' <<<"${lighthouse}")
    found=$(jq --null-input --argjson vd "${visualdiffs}" --argjson lh "${lighthouse}" '($vd + $lh) | length')

    if [[ "${vd_done}" == "true" && "${lh_done}" == "true" ]] && ((found > 0 || SECONDS > empty_deadline)); then
        break
    fi
    if ((SECONDS > deadline)); then
        break
    fi
    sleep 30
done

# The pass/fail rules match what Tugboat uses for GitHub, GitLab, and
# Bitbucket pull requests.
vd_count=$(jq 'length' <<<"${visualdiffs}")
if [[ "${vd_done}" != "true" ]]; then
    post_status "${pr_id}" "${STATUS_VISUALDIFFS}" error "Timed out waiting for Visual Diffs" "${preview_url}/visualdiffs"
elif ((vd_count == 0)); then
    post_status "${pr_id}" "${STATUS_VISUALDIFFS}" notApplicable "No Visual Diffs for this preview" "${preview_url}"
else
    vd_failed=$(jq '[.[] | select(.error or ((.similar >= .threshold) or .approved | not))] | length' <<<"${visualdiffs}")
    if ((vd_failed == 0)); then
        post_status "${pr_id}" "${STATUS_VISUALDIFFS}" succeeded "${vd_count} Visual Diffs passed" "${preview_url}/visualdiffs"
    else
        post_status "${pr_id}" "${STATUS_VISUALDIFFS}" failed "${vd_failed} of ${vd_count} Visual Diffs need review" "${preview_url}/visualdiffs"
    fi
fi

lh_count=$(jq 'length' <<<"${lighthouse}")
if [[ "${lh_done}" != "true" ]]; then
    post_status "${pr_id}" "${STATUS_LIGHTHOUSE}" error "Timed out waiting for Lighthouse reports" "${preview_url}"
elif ((lh_count == 0)); then
    post_status "${pr_id}" "${STATUS_LIGHTHOUSE}" notApplicable "No Lighthouse reports for this preview" "${preview_url}"
else
    # threshold_pass is null when no Lighthouse thresholds are configured.
    lh_failed=$(jq '[.[] | select(.error or .approved == false or (.threshold_pass == false and (.approved | not)))] | length' <<<"${lighthouse}")
    if ((lh_failed == 0)); then
        post_status "${pr_id}" "${STATUS_LIGHTHOUSE}" succeeded "${lh_count} Lighthouse reports passed" "${preview_url}"
    else
        post_status "${pr_id}" "${STATUS_LIGHTHOUSE}" failed "${lh_failed} of ${lh_count} Lighthouse reports need review" "${preview_url}"
    fi
fi
