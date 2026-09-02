#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools cmp find jq nix

homepage_logo_dir="custom_apps/node/apps/homepage/public/logos"
kanidm_logo_dir="modules/Core_Modules/kanidm/assets/apps"

mapfile -t homepage_logos < <(find "$homepage_logo_dir" -maxdepth 1 -type f -name '*.svg' -printf '%f\n' | sort)

if [[ "${#homepage_logos[@]}" -ne 20 ]]; then
  echo "❌ Expected the Homepage service catalog to contain 20 SVG logos; found ${#homepage_logos[@]}." >&2
  exit 1
fi

for logo in "${homepage_logos[@]}"; do
  if [[ ! -f "$kanidm_logo_dir/$logo" ]]; then
    echo "❌ Kanidm is missing the Homepage logo: $logo" >&2
    exit 1
  fi
  if ! cmp -s "$homepage_logo_dir/$logo" "$kanidm_logo_dir/$logo"; then
    echo "❌ Kanidm logo differs from the Homepage source: $logo" >&2
    exit 1
  fi
done

branding_json="$(flake_eval_json '
  host = builtins.getEnv "NIXHOMESERVER_DEFAULT_HOST";
  resolvedHost = if host != "" then host else (import ./vars.nix { inherit lib; }).hostname;
  cfg = (builtins.getAttr resolvedHost f.nixosConfigurations).config;
  kanidmHost = lib.removePrefix "https://" cfg.services.kanidm.server.settings.origin;
in {
  bindReadOnlyPaths = cfg.systemd.services.kanidm.serviceConfig.BindReadOnlyPaths or [ ];
  brandingScript = cfg.systemd.services.kanidm-branding.script;
  caddyConfig = cfg.services.caddy.virtualHosts.${kanidmHost}.extraConfig;
}
')"

if ! jq -e '
  (.bindReadOnlyPaths | any(contains("-override.css:") and endswith("/ui/hpkg/override.css")))
  and (.brandingScript | contains("kanidm system domain remove-image"))
  and (.brandingScript | contains("kanidm system domain set-image") | not)
  and (.caddyConfig | contains("@kanidm_override_css path /pkg/override.css"))
  and (.caddyConfig | contains("Cache-Control \"no-store, max-age=0\""))
' <<<"$branding_json" >/dev/null; then
  echo "❌ Kanidm must mount and revalidate the managed CSS override while retaining its built-in domain logo." >&2
  jq . <<<"$branding_json" >&2
  exit 1
fi

require_fixed modules/audiobookshelf/identity.nix 'assets/apps/audiobookshelf.svg' "Audiobookshelf must use its Homepage logo in Kanidm."
require_fixed modules/beszel/identity.nix 'assets/apps/beszel.svg' "Beszel must use its Homepage logo in Kanidm."
require_fixed modules/files/identity.nix 'assets/apps/filestash.svg' "Filestash must use its Homepage logo in Kanidm."
require_fixed modules/immich/identity.nix 'assets/apps/immich.svg' "Immich must use its Homepage logo in Kanidm."
require_fixed modules/jellyfin/identity.nix 'assets/apps/jellyfin.svg' "Jellyfin must use its Homepage logo in Kanidm."
require_fixed modules/kavita/identity.nix 'assets/apps/kavita.svg' "Kavita must use its Homepage logo in Kanidm."
require_fixed modules/kiwix/identity.nix 'assets/apps/kiwix.svg' "Kiwix must use its Homepage logo in Kanidm."
require_fixed modules/Core_Modules/kopia/identity.nix 'assets/apps/kopia.svg' "Kopia must use its Homepage logo in Kanidm."
require_fixed modules/mail-archive-ui/identity.nix 'assets/apps/mail-archive-ui.svg' "Mail Archive must use its Homepage logo in Kanidm."
require_fixed modules/paperless/identity.nix 'assets/apps/paperless-ngx.svg' "Paperless must use its Homepage logo in Kanidm."
require_fixed modules/prowlarr/identity.nix 'assets/apps/prowlarr.svg' "Prowlarr must use its Homepage logo in Kanidm."
require_fixed modules/qbittorrent/identity.nix 'assets/apps/qbittorrent.svg' "qBittorrent must use its Homepage logo in Kanidm."
require_fixed modules/radarr/identity.nix 'assets/apps/radarr.svg' "Radarr must use its Homepage logo in Kanidm."
require_fixed modules/seerr/identity.nix 'assets/apps/seerr.svg' "Seerr must use its Homepage logo in Kanidm."
require_fixed modules/sonarr/identity.nix 'assets/apps/sonarr.svg' "Sonarr must use its Homepage logo in Kanidm."
require_fixed modules/youtube-downloader/identity.nix 'assets/apps/youtube.svg' "YouTube Downloader must use its Homepage logo in Kanidm."

require_fixed modules/Core_Modules/kanidm/override.css \
  'background-color: var(--nhs-orange);' \
  "Kanidm primary actions must explicitly override Bootstrap's blue button background."

require_fixed scripts/tests/run-script-tests.sh \
  'scripts/tests/test-kanidm-branding.sh' \
  "Kanidm branding regression coverage must run in the lean repository gate."

echo "✅ Kanidm theme installation and service-logo parity tests passed."
