#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools bash nix

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/curl" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

output_file=""
url=""

while (($# > 0)); do
  case "$1" in
    --output)
      output_file="${2:-}"
      shift 2
      ;;
    --write-out)
      shift 2
      ;;
    --silent|--show-error)
      shift
      ;;
    --max-time)
      shift 2
      ;;
    http://*|https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$output_file" || -z "$url" ]]; then
  exit 2
fi

case "$url" in
  https://ok.example.test)
    printf 'ok' >"$output_file"
    printf '200'
    ;;
  https://redirect.example.test)
    printf 'redirect' >"$output_file"
    printf '302'
    ;;
  https://gateway.example.test)
    printf 'Bad Gateway' >"$output_file"
    printf '502'
    ;;
  https://body.example.test)
    printf '502 Bad Gateway' >"$output_file"
    printf '200'
    ;;
  *)
    printf 'missing fixture' >"$output_file"
    printf '404'
    ;;
esac
EOF
make_test_executable "$tmpdir/curl"

run_route_check() {
  PATH="$tmpdir:$PATH" \
    PUBLIC_ROUTE_CHECK_URLS="$1" \
    bash scripts/check-public-routes.sh --attempts 1 --retry-delay 0 --max-time 1 2>&1
}

healthy_output="$(run_route_check $'https://ok.example.test\nhttps://redirect.example.test')"
if ! rg -Fq "Public route checks passed" <<<"$healthy_output"; then
  echo "❌ Public route check should accept non-5xx HTTP responses."
  echo "$healthy_output"
  exit 1
fi

if gateway_output="$(run_route_check "https://gateway.example.test")"; then
  echo "❌ Public route check returned success for HTTP 502."
  exit 1
fi
if ! rg -Fq "HTTP 502" <<<"$gateway_output"; then
  echo "❌ Public route check should report HTTP 502 responses."
  echo "$gateway_output"
  exit 1
fi
if ! rg -Fq "blocked: public route health check failed" <<<"$gateway_output"; then
  echo "❌ Public route check should fail when a route returns Bad Gateway."
  echo "$gateway_output"
  exit 1
fi

if body_output="$(run_route_check "https://body.example.test")"; then
  echo "❌ Public route check returned success for a Bad Gateway response body."
  exit 1
fi
if ! rg -Fq "response body contains Bad Gateway" <<<"$body_output"; then
  echo "❌ Public route check should fail when a response body contains Bad Gateway."
  echo "$body_output"
  exit 1
fi

require_fixed \
  scripts/helpers/deploy-executor.sh \
  "scripts/check-public-routes.sh --hostname" \
  "Deploy executor should run the public route health check after rebuilds."

require_fixed \
  scripts/helpers/deploy-executor.sh \
  "systemctl start homepage-canary.service" \
  "Deploy executor should run the authenticated service-access canary."

require_fixed \
  scripts/helpers/deploy-executor.sh \
  "homepage-canary-assert" \
  "Deploy executor should fail when the canary result is not passing."

echo "✅ Public route check tests passed."
