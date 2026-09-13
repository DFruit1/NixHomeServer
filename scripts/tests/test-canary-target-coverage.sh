#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"

ensure_tools jq nix

# The authenticated Homepage canary is the post-deploy check that a private
# application host is actually reachable through DNS, Caddy, and Kanidm. A host
# that is missing from the canary target list passes deploy silently, so this
# test fails closed whenever an enabled Caddy host is neither covered nor
# explicitly exempted.
coverage_json="$(nix_json '{
  caddyHosts = builtins.attrNames cfg.services.caddy.virtualHosts;
  coveredHosts = cfg.repo.canary.coveredHosts;
  exemptHosts = cfg.repo.canary.coverageExemptHosts;
}')"

missing="$(
  jq -r '
    (.caddyHosts
      | map(select((startswith("http://") | not) and (contains(":") | not)))) as $caddy
    | ($caddy - .coveredHosts - .exemptHosts)[]
  ' <<<"$coverage_json"
)"

if [[ -n "$missing" ]]; then
  echo "❌ Enabled private hosts without authenticated canary coverage:" >&2
  while IFS= read -r host; do
    [[ -n "$host" ]] && printf '   %s\n' "$host" >&2
  done <<<"$missing"
  echo "   Add a target in modules/Core_Modules/homepage/canary.nix or list the" >&2
  echo "   host under repo.canary.coverageExemptHosts with a documented reason." >&2
  exit 1
fi

echo "✅ Every enabled private host has canary coverage or a documented exemption."
