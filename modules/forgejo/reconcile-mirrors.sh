#!/usr/bin/env bash
set -euo pipefail

api="${FORGEJO_API_URL:?FORGEJO_API_URL is required}"
mirror_user="${FORGEJO_MIRROR_USER:?FORGEJO_MIRROR_USER is required}"
mirror_email="${FORGEJO_MIRROR_EMAIL:?FORGEJO_MIRROR_EMAIL is required}"
token_file="${FORGEJO_MIRROR_TOKEN_FILE:?FORGEJO_MIRROR_TOKEN_FILE is required}"
mirrors_file="${FORGEJO_MIRRORS_FILE:?FORGEJO_MIRRORS_FILE is required}"
collaborators="${FORGEJO_MIRROR_COLLABORATORS:-}"
has_github_token="${FORGEJO_MIRRORS_HAS_GITHUB_TOKEN:-0}"

forgejo_bin="${FORGEJO_BIN:-forgejo}"

github_token=""
if [[ "$has_github_token" == "1" && -n "${CREDENTIALS_DIRECTORY:-}" && -s "${CREDENTIALS_DIRECTORY}/github-token" ]]; then
  github_token="$(tr -d '\r\n' <"${CREDENTIALS_DIRECTORY}/github-token")"
fi

log() {
  printf '%s\n' "$*"
}

wait_for_api() {
  local attempt
  for attempt in $(seq 1 150); do
    if curl -fsS --max-time 5 "${api}/api/v1/version" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  log "Forgejo API did not become ready at ${api}"
  return 1
}

ensure_mirror_user() {
  if "$forgejo_bin" admin user list 2>/dev/null | awk 'NR > 1 { print $2 }' | grep -qx "$mirror_user"; then
    return 0
  fi
  log "Creating local Forgejo mirror account '${mirror_user}'"
  "$forgejo_bin" admin user create \
    --username "$mirror_user" \
    --email "$mirror_email" \
    --admin \
    --random-password \
    --must-change-password=false >/dev/null
}

generate_token() {
  local token_name="nixhomeserver-mirror-$(date -u +%Y%m%dT%H%M%S)"
  "$forgejo_bin" admin user generate-access-token \
    --username "$mirror_user" \
    --token-name "$token_name" \
    --scopes "write:repository,write:user" \
    --raw 2>/dev/null | tr -d '\r\n'
}

api_get_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
    -H "Authorization: token ${token}" "$1" || true
}

ensure_token() {
  if [[ ! -s "$token_file" ]]; then
    umask 0077
    generate_token >"$token_file"
  fi
  token="$(cat "$token_file")"
  local code
  code="$(api_get_code "${api}/api/v1/user")"
  if [[ "$code" == "401" || "$code" == "403" ]]; then
    log "Stored mirror token was rejected (HTTP ${code}); issuing a new one"
    umask 0077
    generate_token >"$token_file"
    token="$(cat "$token_file")"
  fi
}

ensure_mirror() {
  local mirror="$1"
  local url owner interval private clone_addr name code payload response

  url="$(jq -r '.url' <<<"$mirror")"
  owner="$(jq -r '.owner' <<<"$mirror")"
  interval="$(jq -r '.interval' <<<"$mirror")"
  private="$(jq -r '.private' <<<"$mirror")"

  clone_addr="${url%/}"
  name="${clone_addr##*/}"
  name="${name%.git}"
  if [[ -z "$url" || "$clone_addr" != */* || -z "$name" ]]; then
    log "Skipping mirror with an unparseable URL: '${url}'"
    return 1
  fi
  if [[ -z "$owner" || "$owner" == "null" ]]; then
    owner="$mirror_user"
  fi

  code="$(api_get_code "${api}/api/v1/repos/${owner}/${name}")"
  if [[ "$code" == "200" ]]; then
    log "Mirror ${owner}/${name} already exists"
  elif [[ "$code" == "404" ]]; then
    payload="$(jq -n \
      --arg clone "$clone_addr" \
      --arg name "$name" \
      --arg owner "$owner" \
      --arg interval "$interval" \
      --argjson private "$private" \
      --arg auth "$github_token" \
      '{
        clone_addr: $clone,
        repo_name: $name,
        repo_owner: $owner,
        mirror: true,
        mirror_interval: $interval,
        private: $private,
        service: "github",
        issues: false,
        pull_requests: false,
        milestones: false,
        labels: false,
        wiki: true,
        releases: false,
        lfs: true
      } + (if $auth == "" then {} else { auth_token: $auth } end)')"
    response="$(curl -sS --max-time 120 -X POST \
      -H "Authorization: token ${token}" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${api}/api/v1/repos/migrate")"
    if jq -e 'has("id")' >/dev/null 2>&1 <<<"$response"; then
      log "Created mirror ${owner}/${name} from ${clone_addr}"
    else
      log "Failed to create mirror ${owner}/${name}: ${response}"
      return 1
    fi
  else
    log "Unexpected HTTP ${code} while checking ${owner}/${name}"
    return 1
  fi

  local user
  local IFS=','
  for user in $collaborators; do
    [[ -n "$user" && "$user" != "$owner" ]] || continue
    curl -s -o /dev/null --max-time 30 -X PUT \
      -H "Authorization: token ${token}" \
      -H "Content-Type: application/json" \
      -d '{"permission":"read"}' \
      "${api}/api/v1/repos/${owner}/${name}/collaborators/${user}" || true
  done
  return 0
}

wait_for_api
ensure_mirror_user
ensure_token

failures=0
while IFS= read -r mirror; do
  [[ -n "$mirror" ]] || continue
  if ! ensure_mirror "$mirror"; then
    failures=$((failures + 1))
  fi
done < <(jq -c '.[]' "$mirrors_file")

if ((failures > 0)); then
  log "${failures} mirror(s) could not be reconciled; the timer will retry."
  exit 1
fi

log "All declarative Forgejo mirrors are reconciled."
