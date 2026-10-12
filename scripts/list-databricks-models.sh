#!/usr/bin/env bash

set -euo pipefail

databricks_url="${DATABRICKS_API_BASE:-${DATABRICKS_HOST:-}}"
databricks_token="${DATABRICKS_TOKEN:-${DATABRICKS_API_KEY:-}}"

: "${databricks_url:?Set DATABRICKS_API_BASE or DATABRICKS_HOST, for example https://adb-...azuredatabricks.net}"
: "${databricks_token:?Set DATABRICKS_TOKEN or DATABRICKS_API_KEY}"

output_format="${OUTPUT_FORMAT:-table}"

databricks_url="${databricks_url%/}"
case "$databricks_url" in
  http://*|https://*) ;;
  *) databricks_url="https://${databricks_url}" ;;
esac

url_scheme="${databricks_url%%://*}"
url_without_scheme="${databricks_url#*://}"
api_base="${url_scheme}://${url_without_scheme%%/*}"

log() {
  printf '[list-databricks-models] %s\n' "$*" >&2
}

api_get() {
  local url="$1"
  local context="$2"
  local response

  response="$(curl -sS -L \
    -H "Authorization: Bearer ${databricks_token}" \
    -H "Accept: application/json" \
    "$url")"

  if ! printf '%s\n' "$response" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf 'Databricks API did not return JSON for %s.\n' "$context" >&2
    exit 1
  fi

  if printf '%s\n' "$response" | jq -e 'has("error_code") or has("error")' >/dev/null; then
    printf 'Databricks API returned an error for %s:\n' "$context" >&2
    printf '%s\n' "$response" | jq . >&2
    exit 1
  fi

  printf '%s\n' "$response"
}

catalogs='[]'
page_token=""
log "Listing Unity Catalog catalogs"
while :; do
  url="${api_base}/api/2.1/unity-catalog/catalogs?max_results=0"
  if [[ -n "$page_token" ]]; then
    page_token_query="$(jq -nr --arg value "$page_token" '$value | @uri')"
    url="${url}&page_token=${page_token_query}"
  fi

  page_json="$(api_get "$url" "list catalogs")"
  catalogs="$(jq -c --argjson page "$page_json" '. + [($page.catalogs // [])[].name]' <<<"$catalogs")"
  page_token="$(printf '%s\n' "$page_json" | jq -r '.next_page_token // empty')"
  log "Fetched catalog page with $(printf '%s\n' "$page_json" | jq '(.catalogs // []) | length') catalogs"

  [[ -n "$page_token" ]] || break
done

parents='[]'
while IFS= read -r catalog; do
  log "Listing schemas for catalog: ${catalog}"
  page_token=""
  while :; do
    catalog_query="$(jq -nr --arg value "$catalog" '$value | @uri')"
    url="${api_base}/api/2.1/unity-catalog/schemas?catalog_name=${catalog_query}&max_results=0"
    if [[ -n "$page_token" ]]; then
      page_token_query="$(jq -nr --arg value "$page_token" '$value | @uri')"
      url="${url}&page_token=${page_token_query}"
    fi

    page_json="$(api_get "$url" "list schemas for ${catalog}")"
    parents="$(jq -c --argjson page "$page_json" '. + [($page.schemas // [])[].full_name | "schemas/" + .]' <<<"$parents")"
    page_token="$(printf '%s\n' "$page_json" | jq -r '.next_page_token // empty')"
    log "Fetched schema page for ${catalog} with $(printf '%s\n' "$page_json" | jq '(.schemas // []) | length') schemas"

    [[ -n "$page_token" ]] || break
  done
done < <(jq -r '.[]' <<<"$catalogs")

if ! jq -e 'length > 0' <<<"$parents" >/dev/null; then
  printf 'Databricks schema APIs did not return any parents.\n' >&2
  exit 1
fi

models='[]'

while IFS= read -r parent; do
  log "Listing model services for parent: ${parent}"
  page_token=""
  while :; do
    parent_query="$(jq -nr --arg value "$parent" '$value | @uri')"
    url="${api_base}/api/2.1/unity-catalog/model-services?parent=${parent_query}&view=BASIC"
    if [[ -n "$page_token" ]]; then
      page_token_query="$(jq -nr --arg value "$page_token" '$value | @uri')"
      url="${url}&page_token=${page_token_query}"
    fi

    page_json="$(api_get "$url" "list model services for ${parent}")"
    models="$(jq -c --argjson page "$page_json" '. + ($page.model_services // [])' <<<"$models")"
    page_token="$(printf '%s\n' "$page_json" | jq -r '.next_page_token // empty')"
    log "Fetched model service page for ${parent} with $(printf '%s\n' "$page_json" | jq '(.model_services // []) | length') model services"

    [[ -n "$page_token" ]] || break
  done
done < <(jq -r '.[]' <<<"$parents")

if ! jq -e 'length > 0' <<<"$models" >/dev/null; then
  printf 'Databricks list-model-services API did not return any model services.\n' >&2
  exit 1
fi

log "Found $(jq 'length' <<<"$models") model services"
log "Writing ${output_format} output"

# shellcheck disable=SC2016
model_filter='
  .[]
  | (.name | sub("^model-services/"; "")) as $full
  | {
      endpoint_name: ($full | split(".")[-1]),
      model_full_name: $full,
      served_entity_name: .name
    }
'

case "$output_format" in
  json)
    jq "[$model_filter] | unique_by(.model_full_name)" <<<"$models"
    ;;
  tsv)
    jq -r "$model_filter | [.endpoint_name, .model_full_name, .served_entity_name] | @tsv" <<<"$models"
    ;;
  table)
    {
      printf 'endpoint_name\tmodel_full_name\tserved_entity_name\n'
      jq -r "$model_filter | [.endpoint_name, .model_full_name, .served_entity_name] | @tsv" <<<"$models"
    } | column -t -s $'\t'
    ;;
  *)
    printf 'Unsupported OUTPUT_FORMAT=%s. Use table, tsv, or json.\n' "$output_format" >&2
    exit 2
    ;;
esac
