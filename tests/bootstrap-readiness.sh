#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools rg nix jq

hostname="$(nix_eval_var 'vars.hostname')"
server_lan_ip="$(nix_eval_var 'vars.serverLanIP')"

echo "ℹ️ Checking bootstrap-critical files are present…"
for required_path in \
  README.md \
  flake.nix \
  flake.lock \
  configuration.nix \
  vars.nix \
  disko.nix \
  scripts/check-repo.sh \
  scripts/runtime-readiness.sh \
  scripts/runtime-validation-report.sh \
  documentation/README.md \
  documentation/first-admin-session.md \
  documentation/quickstart.md \
  documentation/install-from-scratch.md \
  documentation/secrets-and-prereqs.md \
  documentation/networking-and-access.md \
  documentation/operations.md \
  documentation/kanidm.md \
  documentation/runtime-validation.md \
  documentation/runtime-validation-report-template.md \
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
require_match vars.nix 'serverLanIP = ".*";' \
  "vars.nix must define serverLanIP."
require_match vars.nix 'enableDietPiCompanion = (true|false);' \
  "vars.nix must declare whether the DietPi companion is enabled."

echo "ℹ️ Checking deploy and validation guidance is bootstrap-ready…"
require_fixed documentation/quickstart.md "nix flake check --no-build" \
  "Quickstart must document the flake-config-enabled flake-check command."
require_match documentation/quickstart.md 'nix run nixpkgs#nixos-rebuild -- switch \\' \
  "Quickstart must keep the documented workstation deploy flow."
require_fixed documentation/quickstart.md "--flake .#${hostname}" \
  "Quickstart must deploy the hostname from vars.nix."
require_fixed documentation/operations.md "--target-host <admin-user>@<server-lan-ip>" \
  "Operations guide must use portable target-host placeholders."
require_fixed documentation/operations.md "--sudo" \
  "Operations guide must document the non-root remote deploy sudo flow."
require_match documentation/networking-and-access.md 'id\.<domain>' \
  "Networking guide must document id.<domain> as public."
require_match documentation/networking-and-access.md 'files\.<domain>' \
  "Networking guide must document files.<domain> as public."
require_match documentation/networking-and-access.md 'NetBird-only' \
  "Networking guide must document the internal-only app boundary."
require_match documentation/quickstart.md 'tests/run-all\.sh' \
  "Quickstart must include the aggregate policy test entrypoint."
require_match documentation/quickstart.md 'accept-flake-config = true' \
  "Quickstart must explain the one-time flake-config trust option."
require_match documentation/quickstart.md 'First Admin Session' \
  "Quickstart must hand off to the first-admin operator guide after deploy."
require_fixed scripts/check-repo.sh 'export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"' \
  "Repository checks must default NIX_CONFIG for flake-enabled validation."
require_match scripts/runtime-readiness.sh 'cloudflared-tunnel-' \
  "Runtime readiness checks must inspect the concrete cloudflared tunnel unit."
require_match scripts/runtime-readiness.sh 'snapraid diff' \
  "Runtime readiness checks must include SnapRAID drift reporting."
require_match scripts/runtime-validation-report.sh 'Runtime Validation Report' \
  "Runtime validation report helper must emit the report scaffold."
require_fixed modules/paperless/default.nix 'nodejs_20 = pkgs.nodejs_22;' \
  "Paperless must keep the Node 22 frontend override until upstream packaging is stable here."
require_fixed modules/paperless/default.nix "jq 'del(.packageManager)'" \
  "Paperless must strip the frontend packageManager pin to keep builds offline and reproducible."
forbid_match documentation/quickstart.md 'accept invalid\s+certificates' \
  "Quickstart must not document insecure Kanidm certificate bypasses."
forbid_match documentation/operations.md 'accepts invalid certificates' \
  "Operations guide must not document insecure Kanidm certificate bypasses."

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
require_match documentation/quickstart.md "${hostname}" \
  "Quickstart must mention the configured host."
require_match documentation/quickstart.md 'nixos-rebuild test --flake \.#server' \
  "Quickstart must include the local first-activation test flow."
require_match documentation/networking-and-access.md '<domain>' \
  "Networking guide must retain operator-facing domain placeholders."
require_match documentation/operations.md 'paperless-web' \
  "Operations guide must retain Paperless operator guidance."
require_match documentation/operations.md 'cloudflared-tunnel-metro' \
  "Operations guide must document the actual cloudflared tunnel unit."
require_match documentation/operations.md 'host paperless\.<domain> 127\.0\.0\.1' \
  "Operations guide must use host-based DNS checks that work on this server."
require_match documentation/operations.md 'snapraid diff' \
  "Operations guide must document SnapRAID drift checks."
require_match documentation/kanidm.md 'Kanidm' \
  "Kanidm guide must retain identity operator guidance."
require_match documentation/kanidm.md 'immich-users' \
  "Kanidm guide must document the app-specific access groups."
require_match documentation/kanidm.md 'admindsaw' \
  "Kanidm guide must document the intended operator identity."
require_match documentation/operations.md 'users` is baseline identity only' \
  "Operations guide must document that users alone does not grant app access."
require_match documentation/first-admin-session.md 'Access Matrix' \
  "First Admin Session must include the operator access matrix."
require_match documentation/runtime-validation.md 'Expected Behavior Matrix' \
  "Runtime Validation must include the app validation matrix."
require_match documentation/runtime-validation.md 'Validation order' \
  "Runtime Validation must document the ordered validation pass."
require_match documentation/runtime-validation-report-template.md 'Access-control regression summary' \
  "Runtime validation report template must capture regression outcomes."

echo "✅ Bootstrap readiness tests passed."
