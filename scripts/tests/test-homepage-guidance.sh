#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

host="$(test_default_host)"

if [[ "${NIXHOMESERVER_SKIP_NESTED_BUILDS:-0}" != "1" ]]; then
  homepage_config="$(
    nix build --impure --no-link --print-out-paths --expr "
      let f = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
      in f.nixosConfigurations.${host}.config.systemd.services.homepage.environment.HOMEPAGE_CONFIG_FILE
    "
  )"
  sftp_installer="$(
    nix build --impure --no-link --print-out-paths --expr "
      let f = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
      in f.nixosConfigurations.${host}.config.systemd.services.homepage.environment.HOMEPAGE_SFTP_KEY_INSTALL_COMMAND
    "
  )"

  jq -e '
  (.adminUsers | type == "array" and length == 1)
  and (.adminGroups | type == "array")
  and (.sftp.enabled == true)
  and (.sftp.host | type == "string" and length > 0)
  and (.sftp.port | type == "number" and . > 0 and . < 65536)
  and (.sftp.requiredAnyGroups | length > 0)
  and (.offlineMedia.requiredAnyGroups | length > 0)
  and ((.services[] | select(.id == "files")) as $files
    | ($files.requiredAnyGroups | length == 1)
    and ($files.loginNotes | contains($files.requiredAnyGroups[0])))
  and ([.services[] | select(.id != "passwords") | (.requiredAnyGroups // []) | length > 0] | all)
  and ([.services[] | select(.logoUrl != null) | .logoUrl | startswith("/logos/")] | all)
  and ([.services[] | select(.enabled) | (.logoUrl // "") | startswith("/logos/")] | all)
  and (.services[] | select(.id == "photos") | .logoUrl == "/logos/immich.svg")
  and (.services[] | select(.id == "documents") | .logoUrl == "/logos/paperless-ngx.svg")
  and (.services[] | select(.id == "files") | .logoUrl == "/logos/filestash.svg")
  and (.services[] | select(.id == "audiobooks") | .logoUrl == "/logos/audiobookshelf.svg")
  and (.services[] | select(.id == "videos") | .logoUrl == "/logos/jellyfin.svg")
  and (.services[] | select(.id == "videos")
    | (.loginNotes | contains("Kanidm password"))
    and (.loginNotes | contains("/sso/OIDC/QuickConnect/kanidm")))
  and (.services[] | select(.id == "books") | .logoUrl == "/logos/kavita.svg")
  and (.services[] | select(.id == "emails") | .logoUrl == "/logos/mail-archive-ui.svg")
  and (.services[] | select(.id == "passwords") | .logoUrl == "/logos/vaultwarden.svg")
  and ([.folderGuides[] | .personalPath?, .sharedPath? | select(. != null) | startswith("/mnt/data") | not] | all)
  and ([.adminGuide[].title] | index("List storage layout services") != null)
  and ([.adminGuide[].title] | index("Re-run storage layout services") == null)
  and (.adminGuide[] | select(.title == "Validate config readiness") | .command | contains("--identity"))
  and (.adminGuide[] | select(.title == "Restart homepage") | .detail | contains("require a guarded deploy"))
  and (.adminGuide[] | select(.title == "Authenticate Kanidm CLI") | .command | contains("kanidm self whoami"))
  and (.adminGuide[] | select(.title == "Bootstrap or recover operator credential") | .command | contains("kanidm-operator-bootstrap status"))
  and (.adminGuide[] | select(.title == "Retrieve Kopia browser credential")
    | (.command == "sudo nixhomeserver-kopia-browser-credential")
    and (.detail | contains("backup-storage-users alone grants only read-only repository browsing")))
  and (.adminGuide[] | select(.title == "Troubleshoot Jellyfin LAN discovery")
    | (.detail | contains("same IPv4 broadcast network"))
    and (.detail | contains("client isolation"))
    and (.detail | contains("UDP source port 7359")))
  and (.adminGuide[] | select(.title == "Allow Jellyfin discovery replies with nftables")
    | (.command | contains("udp sport 7359"))
    and (.command | test("ip saddr [0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+")))
  and (.adminGuide[] | select(.title == "Allow Jellyfin discovery replies with UFW")
    | (.command | contains("proto udp"))
    and (.command | contains("port 7359")))
  and (.adminGuide[] | select(.title == "Allow Jellyfin discovery replies with firewalld")
    | (.command | contains("source-port port=\"7359\"")))
  and (.adminGuide[] | select(.title == "Allow Jellyfin discovery replies on Windows")
    | (.command | contains("New-NetFirewallRule"))
    and (.command | contains("-RemotePort 7359"))
    and (.command | contains("-Profile Private")))
  and (.adminGuide[] | select(.title == "Allow Jellyfin discovery on Apple devices")
    | (.detail | contains("Local Network"))
    and (.detail | contains("Block all incoming connections")))
' "$homepage_config" >/dev/null || {
    echo "Homepage evaluated guidance/access contract regressed." >&2
    jq . "$homepage_config" >&2
    exit 1
  }

  for required_fragment in 'flock -x 9' 'registered-keys=' 'at most 10 SFTP device keys' 'ssh-keygen -l -f'; do
    if ! rg -Fq "$required_fragment" "$sftp_installer"; then
      echo "SFTP multi-device key safety regressed: missing $required_fragment" >&2
      exit 1
    fi
  done

  key_validation_line="$(rg -n -F 'ssh-keygen -l -f' "$sftp_installer" | head -n 1 | cut -d: -f1)"
  key_storage_line="$(rg -n -F 'install -d -m 0755' "$sftp_installer" | head -n 1 | cut -d: -f1)"
  if [[ -z "$key_validation_line" || -z "$key_storage_line" || "$key_validation_line" -ge "$key_storage_line" ]]; then
    echo "SFTP key structure must be verified before the authorized-keys directory or file is changed." >&2
    exit 1
  fi
  if invalid_key_output="$(
    printf '%s\n' 'ssh-ed25519 AAAA syntactically-plausible-but-corrupt' \
      | "$sftp_installer" homepage-validation-user 2>&1
  )"; then
    echo "SFTP installer accepted a structurally invalid public key." >&2
    exit 1
  fi
  if [[ "$invalid_key_output" != *"invalid or corrupted OpenSSH public key"* ]]; then
    echo "SFTP installer did not report structural public-key validation failure." >&2
    printf '%s\n' "$invalid_key_output" >&2
    exit 1
  fi

  removal_matrix="$(
    NIXHOMESERVER_MODULE_VARIANTS='without-immich,without-paperless,without-jellyfin,without-files' \
      nix eval --impure --json --file scripts/tests/module-removal-matrix.nix
  )"
  text_derivation_payload() {
    nix derivation show "$1" | jq -er '
      (if has("derivations") then .derivations else . end)
      | to_entries
      | if length == 1 and (.[0].value.env.text | type) == "string" then
          .[0].value.env.text
        else
          error("expected exactly one Homepage writeText derivation")
        end
    '
  }
  while IFS=$'\t' read -r variant forbidden_title; do
    config_drv="$(jq -er --arg variant "$variant" '.[$variant].homepageConfigDrv' <<<"$removal_matrix")"
    disabled_homepage_config="$(text_derivation_payload "$config_drv")"
    if jq -e --arg title "$forbidden_title" '.adminGuide | map(.title) | index($title) != null' \
      <<<"$disabled_homepage_config" >/dev/null; then
      echo "$variant left an operator command for its removed service: $forbidden_title" >&2
      exit 1
    fi
  done <<'EOF'
without-immich	Re-run Immich OIDC reconcile
without-paperless	Re-run Paperless OIDC reconcile
without-jellyfin	Re-run Jellyfin library sync
without-jellyfin	Re-run Jellyfin OIDC bootstrap
without-jellyfin	Troubleshoot Jellyfin LAN discovery
without-jellyfin	Allow Jellyfin discovery replies with nftables
without-jellyfin	Allow Jellyfin discovery replies with UFW
without-jellyfin	Allow Jellyfin discovery replies with firewalld
without-jellyfin	Allow Jellyfin discovery replies on Windows
without-jellyfin	Allow Jellyfin discovery on Apple devices
EOF

  without_files_drv="$(jq -er '."without-files".homepageConfigDrv' <<<"$removal_matrix")"
  without_files_homepage_config="$(text_derivation_payload "$without_files_drv")"
  if ! jq -e '
    (.sftp.enabled == true)
    and ([.services[] | select(.id == "files" and .enabled == true)] | length == 0)
  ' <<<"$without_files_homepage_config" >/dev/null; then
    echo "Removing optional Filestash disabled the Core SFTP self-service surface or left Files advertised." >&2
    exit 1
  fi
fi

if rg -n 'logoUrl = "https?://' modules/homepage/services.nix; then
  echo "Homepage service logos must be packaged locally rather than fetched during page views." >&2
  exit 1
fi
while IFS= read -r logo_path; do
  if [[ ! -f "custom_apps/node/apps/homepage/public${logo_path}" ]]; then
    echo "Homepage service logo is referenced but not packaged: ${logo_path}" >&2
    exit 1
  fi
done < <(rg -o -N 'logoUrl = "(/logos/[^"]+)"' modules/homepage/services.nix -r '$1' | sort -u)

if rg -n 'shows live groups|live group catalog' documentation/kanidm.md; then
  echo "Kanidm documentation must not describe evaluated groups as live membership." >&2
  exit 1
fi
require_fixed documentation/operations.md 'never to the backup groups' \
  "Operations guidance must not claim that the non-privileged canary has backup access."

require_fixed modules/homepage/services.nix '++ lib.optionals megaEnabled [' \
  "Homepage must omit MEGA commands when offsite MEGA sync is disabled."
require_fixed custom_apps/node/apps/homepage/src/server/http.ts 'assertFeatureAccess(user, config.homepage.sftp.requiredAllGroups, config.homepage.sftp.requiredAnyGroups)' \
  "SFTP key mutation must enforce the evaluated SFTP access groups."
require_fixed custom_apps/node/apps/homepage/src/server/http.ts 'assertFeatureAccess(user, config.homepage.offlineMedia?.requiredAllGroups, config.homepage.offlineMedia?.requiredAnyGroups)' \
  "Offline-media APIs must enforce the evaluated access groups."
require_fixed custom_apps/node/apps/homepage/src/shared/ui-constants.ts 'sshfs_bin="$(command -v sshfs)"' \
  "Startup guidance must resolve the installed SSHFS binary instead of assuming one installation prefix."
require_fixed custom_apps/node/apps/homepage/src/shared/ui-constants.ts 'fusermount_bin="$(command -v fusermount3 || command -v fusermount)"' \
  "Linux startup guidance must support FUSE 2/3 tools outside an FHS /usr/bin."
if rg -Fq '/usr/local/bin/sshfs' custom_apps/node/apps/homepage/src/shared/ui-constants.ts \
  || rg -Fq '/usr/bin/sshfs' custom_apps/node/apps/homepage/src/shared/ui-constants.ts \
  || rg -Fq '/usr/bin/fusermount' custom_apps/node/apps/homepage/src/shared/ui-constants.ts; then
  echo "SSHFS guidance must support Apple Silicon, NixOS, and non-default install prefixes." >&2
  exit 1
fi
require_fixed modules/homepage/services.nix 'loginNotes = "Requires ${filesWebAccessGroup} for browser access."' \
  "Files guidance must use the evaluated configurable web-access group."
require_fixed modules/homepage/services.nix '++ lib.optionals immichEnabled [' \
  "Homepage must omit Immich reconciliation commands when Immich is disabled."
require_fixed modules/homepage/services.nix '++ lib.optionals paperlessEnabled [' \
  "Homepage must omit Paperless reconciliation commands when Paperless is disabled."
require_fixed modules/homepage/services.nix '++ lib.optionals jellyfinEnabled [' \
  "Homepage must omit Jellyfin synchronization commands when Jellyfin is disabled."
require_fixed custom_apps/node/apps/homepage/src/routes/admins/index.tsx \
  "'Allow Jellyfin discovery replies with nftables': { category: 'network', executionContext: 'Linux client' }" \
  "Homepage must label nftables discovery changes as client-side rather than server-side commands."
require_fixed custom_apps/node/apps/homepage/src/routes/admins/index.tsx \
  "'Allow Jellyfin discovery replies on Windows': { category: 'network', executionContext: 'Windows client (Administrator PowerShell)' }" \
  "Homepage must label the Windows discovery rule with its required client and shell context."
require_fixed documentation/operations.md 'UDP source port `7359` to the client' \
  "Jellyfin discovery guidance must describe the reply direction that stateful client firewalls can misclassify."
require_fixed documentation/operations.md 'New-NetFirewallRule' \
  "Jellyfin discovery guidance must include a narrow Windows Firewall example."
require_fixed documentation/operations.md 'System Settings → Privacy & Security → Local Network' \
  "Jellyfin discovery guidance must cover Apple local-network privacy permission."
require_fixed modules/homepage/services.nix '++ lib.optionals kopiaEnabled [' \
  "Homepage must omit Kopia credential guidance when Kopia is disabled."
require_fixed modules/homepage/services.nix 'command = "sudo systemctl start storage-smart-short.service";' \
  "SMART guidance must invoke the installed server-side service instead of a workstation repository script."
require_fixed modules/homepage/services.nix 'command = "sudo nixhomeserver-storage-inventory --format text";' \
  "Storage inventory guidance must inspect the evaluated server rather than the admin workstation."
require_fixed custom_apps/node/apps/homepage/src/components/SftpSetup.tsx 'SFTP/SSHFS and browser Files access use separate permissions.' \
  "SFTP guidance must not promise browser uploads to accounts without the separate Files permission."
require_fixed custom_apps/node/apps/homepage/src/routes/admins/index.tsx 'This grants every enabled default app group above, not only one app.' \
  "Homepage admin guidance must explain the shared identity.appUsers access bundle."
require_fixed custom_apps/node/apps/homepage/src/routes/admins/index.tsx 'New-user handoff order' \
  "Homepage admin guidance must provide an ordered new-user handoff checklist."
require_fixed custom_apps/node/apps/homepage/src/routes/admins/index.tsx 'Create the one-time account link last' \
  "Homepage admin guidance must delay credential-link creation until access is ready."
require_fixed custom_apps/node/apps/homepage/src/routes/admins/index.tsx 'Display name' \
  "Homepage user creation must collect the human-readable display name separately from the username."
require_fixed custom_apps/node/apps/homepage/src/routes/admins/index.tsx 'Recover the correct sign-in boundary' \
  "Homepage admin guidance must distinguish Kanidm recovery from app-local credentials."
require_fixed custom_apps/node/apps/homepage/src/routes/admins/index.tsx 'Access changes and offboarding' \
  "Homepage admin guidance must explain retained app data and device access during offboarding."
require_fixed custom_apps/node/apps/homepage/src/routes/admins/index.tsx "'Authenticate Kanidm CLI': { category: 'identity', intents: ['add-user', 'manage-user', 'manage-secrets'] }" \
  "Homepage account workflows must surface the required Kanidm CLI authentication step."
require_fixed custom_apps/node/apps/homepage/src/routes/admins/index.tsx 'usernames must start with a lower-case letter' \
  "Homepage account workflows must stop admins from copying commands with invalid usernames."
require_fixed custom_apps/node/apps/homepage/src/routes/admins/index.tsx 'selectedGroups.value = [];' \
  "Homepage access selections must be cleared when their target or workflow changes."
require_fixed custom_apps/node/apps/homepage/src/routes/getting-started/index.tsx 'Never send an admin your password' \
  "New-user guidance must clearly identify credentials that support requests must never include."
require_fixed custom_apps/node/apps/homepage/src/routes/getting-started/index.tsx 'Use a trusted network path' \
  "New-user guidance must explain the private LAN or NetBird access requirement."
require_fixed custom_apps/node/apps/homepage/src/routes/getting-started/index.tsx 'Choose what to set up' \
  "New-user guidance must introduce the complete setup checklist before account setup."
require_fixed custom_apps/node/apps/homepage/src/routes/getting-started/index.tsx 'Immich, Jellyfin, Inkita, Lissen, and Audiobookshelf' \
  "New-user guidance must recommend the supported Android clients in one place."
require_fixed custom_apps/node/apps/homepage/src/routes/getting-started/index.tsx 'progress is saved only in this browser profile' \
  "New-user guidance must not imply that checklist progress is stored server-side."
require_fixed custom_apps/node/apps/homepage/src/routes/getting-started/index.tsx 'Browser Files and SFTP/SSHFS are separate permissions.' \
  "New-user guidance must explain the separate browser and direct-file-transfer permissions."
require_fixed custom_apps/node/apps/homepage/src/routes/getting-started/index.tsx 'Local Backups has two sign-in gates.' \
  "New-user guidance must distinguish Kanidm gateway access from the native Kopia login."
require_fixed custom_apps/node/apps/homepage/src/routes/getting-started/index.tsx 'Some app accounts are created on first sign-in.' \
  "New-user guidance must explain first-login provisioning for apps that keep local accounts."
require_fixed custom_apps/node/apps/homepage/src/routes/getting-started/index.tsx 'Do not use a public photo-share link or the public share hostname' \
  "Mobile Photos guidance must distinguish the private app URL from public share links."
require_fixed custom_apps/node/apps/homepage/src/components/OfflineMediaSetup.tsx 'Syncthing-Fork is the supported app.' \
  "Offline Media guidance must name the single supported mobile app."
require_fixed custom_apps/node/apps/homepage/src/components/OfflineMediaSetup.tsx 'iPhone and iPad are not supported.' \
  "Offline Media guidance must state the unsupported iOS boundary."
require_fixed custom_apps/node/apps/homepage/src/components/OfflineMediaSetup.tsx 'offline-media-status-column' \
  "Offline Media must keep the server QR code and connection status in the dedicated layout column."
if rg -Fq 'Möbius Sync' custom_apps/node/apps/homepage/src/components/OfflineMediaSetup.tsx; then
  echo "Offline Media must not advertise an unsupported iOS client." >&2
  exit 1
fi
require_fixed custom_apps/node/apps/homepage/src/routes/getting-started/index.tsx 'No enabled apps are currently assigned to this account' \
  "New-user guidance must make an empty app assignment a skippable state."
require_fixed custom_apps/node/apps/homepage/src/routes/admins/index.tsx "group === 'app-admin'" \
  "Selecting app-admin must automatically include the normal application-access bundle."
require_fixed custom_apps/node/apps/homepage/src/routes/admins/index.tsx 'Configured access boundaries and exceptions' \
  "Admin access guidance must surface configured native-login, file-role, and app-admin exceptions."
require_fixed custom_apps/node/apps/homepage/src/routes/admins/index.tsx "'Revoke offline-media device access': { category: 'identity', intents: ['manage-user'] }" \
  "Offline-media offboarding must surface under user-access administration."
require_fixed custom_apps/node/apps/homepage/src/routes/admins/index.tsx 'File and backup roles are independent manual Kanidm groups' \
  "Homepage admin guidance must keep backup roles independently Kanidm-managed."
require_fixed modules/homepage/services.nix '"manual"' \
  "Homepage group metadata must identify Kanidm-managed membership."
require_fixed custom_apps/node/apps/homepage/src/components/CredentialBackupGuide.tsx '.zip (with attachments)' \
  "Vault recovery guidance must explain the separate attachment export."
require_fixed custom_apps/node/apps/homepage/src/components/CredentialBackupGuide.tsx 'Treat that archive as plaintext vault data' \
  "The attachment archive must be identified as sensitive plaintext."

echo "✅ Homepage guidance and authorization regression tests passed."
