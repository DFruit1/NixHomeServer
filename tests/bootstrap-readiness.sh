#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools rg nix jq

hostname="$(nix_eval_var 'vars.hostname')"
server_lan_ip="$(nix_eval_var 'vars.serverLanIP')"

echo "ℹ️ Checking bootstrap-critical files are present…"
for required_path in \
  flake.nix \
  flake.lock \
  configuration.nix \
  vars.nix \
  disko.nix \
  scripts/check-repo.sh \
  documentation/bootstrap.md \
  documentation/manual_steps.txt \
  secrets/agenix.nix
do
  if [[ ! -e "$required_path" ]]; then
    echo "❌ Bootstrap-critical file is missing: $required_path"
    exit 1
  fi
done

echo "ℹ️ Checking vars.nix remains the bootstrap source of truth…"
require_fixed vars.nix 'hostname = "server";' \
  "vars.nix must keep the canonical hostname."
require_fixed vars.nix 'serverLanIP = "192.168.0.144";' \
  "vars.nix must keep the canonical server LAN IP."
require_fixed vars.nix 'enableDietPiCompanion = false;' \
  "vars.nix must declare whether the DietPi companion is enabled."

echo "ℹ️ Checking deploy and validation guidance is bootstrap-ready…"
require_match documentation/bootstrap.md 'nix run nixpkgs#nixos-rebuild -- switch \\' \
  "Bootstrap guide must keep the documented workstation deploy flow."
require_match documentation/manual_steps.txt 'nix run nixpkgs#nixos-rebuild -- switch \\' \
  "Manual steps must keep the documented workstation deploy flow."
require_fixed documentation/bootstrap.md "--flake .#${hostname}" \
  "Bootstrap guide must deploy the hostname from vars.nix."
require_fixed documentation/manual_steps.txt "--target-host root@${server_lan_ip}" \
  "Manual steps must target the server LAN IP from vars.nix."
require_match documentation/bootstrap.md 'Application hostnames such as `paperless`, `immich`, `photoshare`, and `audiobookshelf` are intended to stay \*\*LAN/NetBird-only\*\*' \
  "Bootstrap guide must document the internal-only app boundary."
require_match documentation/manual_steps.txt 'Public Cloudflare exposure should stay limited to `id`\.<domain> and `fileshare`\.<domain>' \
  "Manual steps must document the limited Cloudflare public exposure set."
require_match documentation/bootstrap.md 'tests/run-all\.sh' \
  "Bootstrap guide must include the aggregate policy test entrypoint."

echo "ℹ️ Checking required bootstrap secrets are declared…"
for secret_name in \
  cfAPIToken \
  cfHomeCreds \
  netbirdSetupKey \
  kanidmAdminPass \
  kanidmSysAdminPass
do
  require_match secrets/agenix.nix "${secret_name}\\s*=" \
    "secrets/agenix.nix must declare ${secret_name}."
done

echo "ℹ️ Checking hostname and service names stay represented in operator docs…"
require_match documentation/bootstrap.md "${hostname}" \
  "Bootstrap guide must mention the configured host."
require_match documentation/bootstrap.md '<domain>' \
  "Bootstrap guide must retain the operator-facing domain placeholder."
require_match documentation/manual_steps.txt 'paperless-web' \
  "Manual steps must retain Paperless operator guidance."
require_match documentation/manual_steps.txt 'kanidm' \
  "Manual steps must retain Kanidm operator guidance."

echo "✅ Bootstrap readiness tests passed."
