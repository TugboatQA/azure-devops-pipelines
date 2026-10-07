#!/usr/bin/env bash
# shellcheck disable=SC2034 # The scripts that source this file use its variables.
# Shared helpers for the Tugboat Azure Pipelines scripts. Source this file;
# do not run it directly.
#
# Required environment:
#   TUGBOAT_API_TOKEN   Tugboat access token (secret pipeline variable)
#   TUGBOAT_REPO        Tugboat Repository ID
#   SYSTEM_ACCESSTOKEN  Mapped from $(System.AccessToken) in the pipeline YAML
#
# Optional environment:
#   TUGBOAT_API         Defaults to https://api.tugboatqa.com/v3
#   TUGBOAT_DASHBOARD   Defaults to https://dashboard.tugboatqa.com

set -euo pipefail

TUGBOAT_API="${TUGBOAT_API:-https://api.tugboatqa.com/v3}"
TUGBOAT_DASHBOARD="${TUGBOAT_DASHBOARD:-https://dashboard.tugboatqa.com}"

# Every preview these pipelines create has a name that starts with this prefix,
# the pull request ID, and a colon, for example "Azure PR #42: Add a header".
# The prefix separates these previews from previews that people create by hand.
PREVIEW_NAME_PREFIX="Azure PR #"

# Status check names, matching what Tugboat posts to GitHub, GitLab, and
# Bitbucket.
STATUS_GENRE="tugboat"
STATUS_BUILD="Tugboat"
STATUS_VISUALDIFFS="Tugboat - Visual Diffs"
STATUS_LIGHTHOUSE="Tugboat - Lighthouse Reports"

# The pull request comment with the preview links starts with this text. The
# scripts find the comment again by this prefix.
COMMENT_HEADER="[Tugboat](https://www.tugboatqa.com)"

# _curl_json METHOD URL TOKEN [JSON_BODY]
_curl_json() {
    local args=(--silent --show-error --fail-with-body --request "$1"
        --header "Authorization: Bearer $3"
        --header "Content-Type: application/json")
    if [[ -n "${4:-}" ]]; then
        args+=(--data "$4")
    fi
    curl "${args[@]}" "$2"
}

# tugboat_api METHOD PATH [JSON_BODY]
tugboat_api() {
    _curl_json "$1" "${TUGBOAT_API}$2" "${TUGBOAT_API_TOKEN}" "${3:-}"
}

# azure_api METHOD PATH [JSON_BODY]
#
# PATH is relative to this pipeline's Git repository, for example
# "/pullRequests/42". Authenticates as the pipeline's build service identity.
azure_api() {
    local url="${SYSTEM_COLLECTIONURI}${SYSTEM_TEAMPROJECTID}/_apis/git/repositories/${BUILD_REPOSITORY_ID}$2"
    if [[ "${url}" == *\?* ]]; then
        url+="&api-version=7.1"
    else
        url+="?api-version=7.1"
    fi
    _curl_json "$1" "${url}" "${SYSTEM_ACCESSTOKEN}" "${3:-}"
}

# list_previews prints the JSON array of all previews in TUGBOAT_REPO.
list_previews() {
    tugboat_api GET "/repos/${TUGBOAT_REPO}/previews"
}

# pr_previews PREVIEWS_JSON prints "PREVIEW_ID PR_ID" for every preview these
# pipelines created.
pr_previews() {
    jq --raw-output --arg prefix "${PREVIEW_NAME_PREFIX}" '
        .[]
        | (.name // "") as $name
        | select($name | test("^" + $prefix + "[0-9]+:"))
        | "\(.id) \($name | ltrimstr($prefix) | split(":")[0])"' <<<"$1"
}

# find_pr_preview PREVIEWS_JSON PR_ID prints the ID of the pull request's
# preview, or nothing.
find_pr_preview() {
    pr_previews "$1" | awk -v pr="$2" '$2 == pr && !found { print $1; found = 1 }'
}

# wait_for_job JOB_ID polls the Tugboat job until it ends and prints the final
# job JSON.
wait_for_job() {
    local job
    while true; do
        job=$(tugboat_api GET "/jobs/$1")
        if jq --exit-status '.endedAt' <<<"${job}" >/dev/null; then
            echo "${job}"
            return
        fi
        sleep 15
    done
}

# post_status PR_ID CONTEXT_NAME STATE DESCRIPTION [TARGET_URL]
#
# STATE is one of: pending, succeeded, failed, error, notApplicable, notSet.
post_status() {
    local body
    body=$(jq --null-input \
        --arg genre "${STATUS_GENRE}" --arg name "$2" \
        --arg state "$3" --arg description "$4" --arg url "${5:-}" \
        '{state: $state, description: $description, context: {genre: $genre, name: $name}}
         + (if $url == "" then {} else {targetUrl: $url} end)')
    azure_api POST "/pullRequests/$1/statuses" "${body}" >/dev/null
}

# preview_reports PREVIEW_ID prints the preview's Visual Diffs and Lighthouse
# reports as {"visualdiffs": [...], "lighthouse": [...]}.
preview_reports() {
    local visualdiffs="[]" lighthouse="[]" service_id screenshot_id
    for service_id in $(tugboat_api GET "/previews/$1/services" | jq --raw-output '.[].id'); do
        lighthouse=$(jq --slurp 'add' <<<"${lighthouse} $(tugboat_api GET "/services/${service_id}/lighthouse")")
        for screenshot_id in $(tugboat_api GET "/services/${service_id}/screenshots" | jq --raw-output '.[].id'); do
            visualdiffs=$(jq --slurp 'add' <<<"${visualdiffs} $(tugboat_api GET "/screenshots/${screenshot_id}/visualdiffs")")
        done
    done
    jq --null-input --argjson vd "${visualdiffs}" --argjson lh "${lighthouse}" '{visualdiffs: $vd, lighthouse: $lh}'
}

# report_statuses PREVIEW_JSON REPORTS_JSON prints a JSON array with one
# {name, state, description, url} object for each of the Visual Diffs and
# Lighthouse status checks.
#
# A report is finished when it has a result or an error and was updated after
# the preview's latest build began; older reports are from the previous build.
# The pass/fail rules match what Tugboat uses for GitHub, GitLab, and Bitbucket
# pull requests. Lighthouse threshold_pass is null when no thresholds are set.
report_statuses() {
    jq --null-input --argjson preview "$1" --argjson reports "$2" \
        --arg dashboard "${TUGBOAT_DASHBOARD}" \
        --arg vd_name "${STATUS_VISUALDIFFS}" --arg lh_name "${STATUS_LIGHTHOUSE}" '
        def status($name; $url; $items; $finished; $failed; $noun):
            {name: $name, url: $url}
            + if ($items | length) == 0 then
                {state: "notApplicable", description: "No \($noun) for this preview"}
            elif ($finished | not) then
                {state: "pending", description: "Waiting for \($noun)"}
            elif $failed == 0 then
                {state: "succeeded", description: "\($noun) passed (\($items | length))"}
            else
                {state: "failed", description: "\($failed) of \($items | length) \($noun) need review"}
            end;

        ($preview.build_begin // "") as $since
        | "\($dashboard)/\($preview.id)" as $url
        | $reports.visualdiffs as $vd
        | $reports.lighthouse as $lh
        | [
            status($vd_name; "\($url)/visualdiffs"; $vd;
                all($vd[]; .updatedAt >= $since and (.size or .error));
                [$vd[] | select(.error or ((.similar >= .threshold) or .approved | not))] | length;
                "Visual Diffs"),
            status($lh_name; $url; $lh;
                all($lh[]; .updatedAt >= $since and (.summary or .error));
                [$lh[] | select(.error or .approved == false or (.threshold_pass == false and (.approved | not)))] | length;
                "Lighthouse reports")
        ]'
}

# post_report_statuses PR_ID STATUSES_JSON posts each status from
# report_statuses, skipping any that match the status already on the pull
# request.
post_report_statuses() {
    local current name state description url
    current=$(azure_api GET "/pullRequests/$1/statuses" | jq '
        [.value | group_by(.context.name)[] | max_by(.id) | {name: .context.name, state, description}]')
    while IFS=$'\t' read -r name state description url; do
        if jq --exit-status --arg name "${name}" --arg state "${state}" --arg description "${description}" \
            'any(.[]; .name == $name and .state == $state and .description == $description)' \
            <<<"${current}" >/dev/null; then
            echo "${name}: unchanged (${description})"
            continue
        fi
        echo "${name}: ${state} (${description})"
        post_status "$1" "${name}" "${state}" "${description}" "${url}"
    done < <(jq --raw-output '.[] | [.name, .state, .description, .url] | @tsv' <<<"$2")
}

# find_comment PR_ID prints "THREAD_ID COMMENT_ID" for the pull request's
# preview links comment, or nothing.
find_comment() {
    azure_api GET "/pullRequests/$1/threads" | jq --raw-output --arg header "${COMMENT_HEADER}" '
        first(.value[]
            | select(.isDeleted | not)
            | .id as $thread
            | .comments[0]
            | select((.isDeleted | not) and ((.content // "") | startswith($header)))
            | "\($thread) \(.id)") // empty'
}

# set_comment PR_ID BODY [MODE]
#
# Updates the pull request's preview links comment. With MODE "post", posts a
# new comment when none exists. With MODE "edit" (the default), only updates an
# existing comment. This matches how Tugboat updates its comment in place on
# GitHub, GitLab, and Bitbucket.
set_comment() {
    local pr_id="$1" body="$2" mode="${3:-edit}" found thread_id comment_id
    found=$(find_comment "${pr_id}")
    if [[ -n "${found}" ]]; then
        read -r thread_id comment_id <<<"${found}"
        body+=$'\n\n'"_Last updated: $(date -u '+%a, %d %b %Y %H:%M:%S GMT')_"
        azure_api PATCH "/pullRequests/${pr_id}/threads/${thread_id}/comments/${comment_id}" \
            "$(jq --null-input --arg content "${body}" '{content: $content}')" >/dev/null
    elif [[ "${mode}" == "post" ]]; then
        azure_api POST "/pullRequests/${pr_id}/threads" \
            "$(jq --null-input --arg content "${body}" \
                '{comments: [{parentCommentId: 0, content: $content, commentType: 1}]}')" >/dev/null
    fi
}

# comment_links_body PREVIEW_JSON prints the preview links comment, in the same
# format Tugboat uses on GitHub, GitLab, and Bitbucket.
comment_links_body() {
    local preview_id services
    preview_id=$(jq --raw-output '.id' <<<"$1")
    services=$(tugboat_api GET "/previews/${preview_id}/services")
    jq --raw-output --null-input --argjson preview "$1" --argjson services "${services}" \
        --arg header "${COMMENT_HEADER}" --arg dashboard "${TUGBOAT_DASHBOARD}" '
        "\($dashboard)/\($preview.id)" as $url
        | [$services[] | select((.urls // []) | length > 0)]
        | sort_by([(.config.default != true), (.name | ascii_downcase)]) as $exposed
        | "\($header) has finished building the preview for this pull request!\n\n"
        + ($exposed | map(
            (if .config.default then "" else " (\(.name))" end) as $suffix
            | (if (.urls | length) == 1 then "Link" else "Links" end) + "\($suffix):\n"
            + (.urls | map("- \(.)\n") | join(""))
            + "\n") | join(""))
        + "Dashboard:\n- \($url)\n"
        + (if $preview.base and any($services[]; (.config.urls // []) | length > 0)
            then "\nVisual Diffs:\n- \($url)/visualdiffs\n"
            else "" end)'
}
