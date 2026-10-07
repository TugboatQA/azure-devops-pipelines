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
    local url="${SYSTEM_COLLECTIONURI}${SYSTEM_TEAMPROJECTID}/_apis/git/repositories/${BUILD_REPOSITORY_ID}$2?api-version=7.1"
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
