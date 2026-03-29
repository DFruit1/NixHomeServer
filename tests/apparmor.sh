#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools rg sed sort mktemp

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

profiles_file="${tmpdir}/profiles.txt"

rg --no-filename -o -N 'AppArmorProfile = "generated-([^"]+)"' modules configuration.nix -r '$1' \
  | sort -u >"$profiles_file"

echo "ℹ️ Checking AppArmor profile coverage and naming…"
require_fixed modules/apparmor/default.nix 'state = "complain";' \
  "Generated AppArmor policies must default to complain mode."
require_fixed modules/apparmor/default.nix 'lib.nameValuePair ("generated-" + n)' \
  "AppArmor module must generate profile names from the underlying service keys."

while IFS= read -r profile; do
  [[ -n "$profile" ]] || continue
  if ! rg -q --multiline -- "(^|[[:space:]])\"?${profile}\"?[[:space:]]*=[[:space:]]*\\[" modules/apparmor/default.nix vars.nix; then
    echo "❌ Every referenced AppArmor profile must have a base profile or vars.nix entry."
    echo "   Missing profile key: ${profile}"
    exit 1
  fi
done <"$profiles_file"

require_fixed modules/cloudflared/default.nix 'systemd.services."cloudflared-tunnel-${vars.cloudflareTunnelName}".serviceConfig.AppArmorProfile =' \
  "Cloudflared tunnel unit must have an AppArmor profile assignment."
require_fixed modules/netbird/default.nix 'systemd.services."netbird-main".serviceConfig.AppArmorProfile = "generated-netbird-main";' \
  "NetBird main unit must have an AppArmor profile assignment."
require_fixed modules/paperless/default.nix 'systemd.services."paperless-web".serviceConfig.AppArmorProfile = "generated-paperless-web";' \
  "Paperless web unit must have an AppArmor profile assignment."
require_fixed modules/kanidm/default.nix 'systemd.services.kanidm = {' \
  "Kanidm service must remain explicitly configurable for AppArmor."
require_fixed vars.nix '"cloudflared-tunnel-${cloudflareTunnelName}" = [ "/var/lib/cloudflared/**" "/var/log/cloudflared/**" "/etc/cloudflared/**" ];' \
  "vars.nix must keep the cloudflared unit profile key aligned with the real unit name."
require_fixed vars.nix '"netbird-main" = [ "/var/lib/netbird-main/**" "/var/log/netbird-main/**" "/etc/netbird-main/**" ];' \
  "vars.nix must keep the netbird-main profile key aligned with the real unit name."
require_fixed vars.nix '"paperless-web" = [ "${dataRoot}/paperless/**" "/var/lib/paperless/**" "/var/log/paperless-ngx/**" ];' \
  "vars.nix must keep the paperless-web profile key aligned with the real unit name."

echo "✅ AppArmor policy tests passed."
