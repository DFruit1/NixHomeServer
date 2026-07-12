#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/helpers/repo-common.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/check-public-routes.sh [--hostname <flake-hostname>] [--url <url>] [--attempts <count>] [--retry-delay <seconds>] [--max-time <seconds>]

Check public Caddy routes for gateway/server errors. By default, URLs are
derived from evaluated Caddy virtual hosts under vars.domain.

PUBLIC_ROUTE_CHECK_URLS may be set to a newline-delimited URL list for tests.
EOF
}

hostname=""
attempts="${PUBLIC_ROUTE_CHECK_ATTEMPTS:-3}"
retry_delay="${PUBLIC_ROUTE_CHECK_RETRY_DELAY:-5}"
max_time="${PUBLIC_ROUTE_CHECK_MAX_TIME:-15}"
declare -a explicit_urls=()

while (($# > 0)); do
  case "$1" in
    --hostname)
      hostname="${2:-}"
      shift 2
      ;;
    --url)
      explicit_urls+=("${2:-}")
      shift 2
      ;;
    --attempts)
      attempts="${2:-}"
      shift 2
      ;;
    --retry-delay)
      retry_delay="${2:-}"
      shift 2
      ;;
    --max-time)
      max_time="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$hostname" ]]; then
  hostname="$(nix_flake_var 'vars.hostname')"
fi

if ! [[ "$attempts" =~ ^[1-9][0-9]*$ ]]; then
  echo "blocked: --attempts must be a positive integer" >&2
  exit 1
fi

if ! [[ "$retry_delay" =~ ^[0-9]+$ ]]; then
  echo "blocked: --retry-delay must be a non-negative integer" >&2
  exit 1
fi

if ! [[ "$max_time" =~ ^[1-9][0-9]*$ ]]; then
  echo "blocked: --max-time must be a positive integer" >&2
  exit 1
fi

nix_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '"%s"' "$value"
}

resolve_public_route_urls() {
  local hostname_nix
  hostname_nix="$(nix_string "$hostname")"

  nix eval --raw --impure --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      lib = flake.inputs.nixpkgs.lib;
      vars = import ${repo_root}/vars.nix { inherit lib; };
      cfg = (builtins.getAttr ${hostname_nix} flake.nixosConfigurations).config;
      tunnel = cfg.services.cloudflared.tunnels.\${vars.cloudflareTunnelName};
      domainSuffix = \".\${vars.domain}\";
      publicHost = host:
        host != \"default\"
        && !(lib.hasPrefix \"http://\" host)
        && (host == vars.domain || lib.hasSuffix domainSuffix host);
      hosts = builtins.filter publicHost (builtins.attrNames tunnel.ingress);
    in
      builtins.concatStringsSep \"\n\" (map (host: \"https://\${host}\") hosts)
  "
}

load_urls() {
  if ((${#explicit_urls[@]} > 0)); then
    printf '%s\n' "${explicit_urls[@]}"
    return 0
  fi

  if [[ -n "${PUBLIC_ROUTE_CHECK_URLS:-}" ]]; then
    printf '%s\n' "$PUBLIC_ROUTE_CHECK_URLS"
    return 0
  fi

  resolve_public_route_urls
}

need nix

if ! command -v curl >/dev/null 2>&1; then
  echo "blocked: curl is required for public route checks" >&2
  exit 1
fi

declare -a urls=()
while IFS= read -r url; do
  [[ -n "$url" ]] || continue
  urls+=("$url")
done < <(load_urls)

if ((${#urls[@]} == 0)); then
  echo "blocked: no public routes were found to check" >&2
  exit 1
fi

check_url_once() {
  local url="$1"
  local body_file status curl_status

  body_file="$(mktemp /tmp/public-route-check.XXXXXX)"
  set +e
  status="$(curl \
    --silent \
    --show-error \
    --max-time "$max_time" \
    --output "$body_file" \
    --write-out '%{http_code}' \
    "$url")"
  curl_status=$?
  set -e

  if ((curl_status != 0)); then
    rm -f "$body_file"
    echo "curl failed with exit ${curl_status}"
    return 1
  fi

  if [[ ! "$status" =~ ^[0-9][0-9][0-9]$ ]]; then
    rm -f "$body_file"
    echo "unexpected HTTP status '${status}'"
    return 1
  fi

  if [[ "$status" =~ ^5 ]]; then
    rm -f "$body_file"
    echo "HTTP ${status}"
    return 1
  fi

  if grep -aiq 'bad gateway' "$body_file"; then
    rm -f "$body_file"
    echo "response body contains Bad Gateway"
    return 1
  fi

  rm -f "$body_file"
  echo "HTTP ${status}"
  return 0
}

failures=0

for url in "${urls[@]}"; do
  echo "checking public route: ${url}"
  last_result=""

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if last_result="$(check_url_once "$url")"; then
      echo "ok: ${url} ${last_result}"
      continue 2
    fi

    if ((attempt < attempts)); then
      echo "retrying: ${url} ${last_result}"
      sleep "$retry_delay"
    fi
  done

  echo "blocked: ${url} ${last_result}" >&2
  failures=$((failures + 1))
done

if ((failures > 0)); then
  echo "blocked: public route health check failed for ${failures} route(s)" >&2
  exit 1
fi

echo "✅ Public route checks passed."
