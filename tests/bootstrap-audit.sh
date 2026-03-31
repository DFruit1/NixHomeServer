#!/usr/bin/env bash

set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools nix systemctl curl ss rg

domain="$(nix_eval_var 'vars.domain')"
kanidm_domain="$(nix_eval_var 'vars.kanidmDomain')"

failures=0

run_check() {
  local name="$1"
  local cmd="$2"
  local hint="$3"

  if check_cmd "$cmd"; then
    echo "✅ ${name}"
  else
    echo "❌ ${name}"
    echo "   What to check: ${hint}"
    echo "   Reproduce manually: ${cmd}"
    failures=$((failures + 1))
  fi
}

check_cmd() {
  local cmd="$1"
  bash -lc "$cmd" >/dev/null 2>&1
}

echo "ℹ️ Running first-bootstrap runtime audit (non-blocking per check)…"
echo "   This script continues after failures so you can see all outstanding items in one run."

run_check \
  "Cloudflare tunnel service is running" \
  "systemctl is-active --quiet cloudflared" \
  "Cloudflare Tunnel must be active for public ingress."
run_check \
  "Caddy reverse proxy service is running" \
  "systemctl is-active --quiet caddy" \
  "Caddy must be active to terminate TLS and route hostnames locally."
run_check \
  "Kanidm service is running" \
  "systemctl is-active --quiet kanidm" \
  "Kanidm must be up for identity/OIDC flows."
run_check \
  "OAuth2 Proxy service is running" \
  "systemctl is-active --quiet oauth2-proxy" \
  "OAuth2 Proxy must be active for fileshare auth protection."
run_check \
  "NetBird service is running" \
  "systemctl is-active --quiet netbird" \
  "NetBird must be active for mesh connectivity."
run_check \
  "Unbound DNS service is running" \
  "systemctl is-active --quiet unbound" \
  "Unbound must be active for local resolver behavior."
run_check \
  "Host is listening on HTTPS/HTTP ports (443/80)" \
  "ss -tulpn | rg -q ':(80|443)\\b'" \
  "A reverse proxy listener should be present on 80/443."
run_check \
  "id.<domain> responds through local Caddy routing" \
  "curl -kI --resolve \"${kanidm_domain}:443:127.0.0.1\" https://${kanidm_domain}/" \
  "The Kanidm public hostname should resolve and respond through local Caddy."
run_check \
  "fileshare.<domain> responds through local Caddy routing" \
  "curl -kI --resolve \"fileshare.${domain}:443:127.0.0.1\" https://fileshare.${domain}/" \
  "The fileshare public hostname should resolve and respond through local Caddy."

if (( failures > 0 )); then
  echo
  echo "❌ Bootstrap runtime audit found ${failures} failing check(s)."
  echo "   Fix the items above, then rerun: tests/bootstrap-audit.sh"
  exit 1
fi

echo "✅ Bootstrap runtime audit passed."
