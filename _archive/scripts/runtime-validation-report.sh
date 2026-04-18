#!/usr/bin/env bash

set -euo pipefail

repo_root="${RUNTIME_VALIDATION_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$repo_root"

export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

need() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Missing required tool: $tool" >&2
      exit 1
    fi
  done
}

nix_var() {
  local expr="$1"
  nix eval --raw --impure --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      vars = import ${repo_root}/vars.nix { lib = flake.inputs.nixpkgs.lib; };
    in
      ${expr}
  "
}

need nix date

hostname="$(nix_var 'vars.hostname')"
domain="$(nix_var 'vars.domain')"
kanidm_domain="$(nix_var 'vars.kanidmDomain')"
files_domain="$(nix_var 'vars.filesDomain')"
photos_domain="$(nix_var 'vars.photosDomain')"
audiobooks_domain="$(nix_var 'vars.audiobooksDomain')"
kavita_domain="$(nix_var 'vars.kavitaDomain')"
jellyfin_domain="$(nix_var 'vars.jellyfinDomain')"
jellyseerr_domain="$(nix_var 'vars.jellyseerrDomain')"
report_date="$(date -Iseconds)"

cat <<EOF
# Runtime Validation Report

- Date: ${report_date}
- Host: ${hostname}
- Domain: ${domain}
- Operator:
- NetBird client used:
- Build or generation tested:
- Notes:

## Baseline readiness

- \`./scripts/runtime-readiness.sh\`:
- Public path reachable:
  - \`https://${kanidm_domain}\`
  - \`https://${files_domain}\`
- Private NetBird path reachable:
  - \`https://paperless.${domain}\`
  - \`https://${photos_domain}\`
  - \`https://${audiobooks_domain}\`
  - \`https://${kavita_domain}\`
  - \`https://${jellyfin_domain}\`
  - \`https://${jellyseerr_domain}\`
- DNS answers correct:
- \`/mnt/data\` mounted:
- \`/mnt/parity\` mounted:
- \`snapraid status\`:
- \`snapraid diff\`:

## Personas used

| Persona | Username | Groups | Notes |
|---|---|---|---|
| Delegated operator | \`admindsaw\` | seeded admin-intent groups plus \`users\` |  |
| Daily-use user | \`dsaw\` |  |  |
| Baseline test user | \`test-basic\` | \`users\` |  |
| Files test user | \`test-files\` | \`users\`, \`fileshare_users\` |  |
| App login test user | \`test-app-user\` | \`users\`, one app login group at a time |  |
| App admin test user | \`test-app-admin\` | \`users\`, one app admin group at a time |  |
| Optional delegated admin test user | \`test-idm-admin\` | \`users\`, \`idm_admins\` |  |

## Kanidm delegated admin bootstrap

- \`admindsaw\` login:
- \`kanidm reauth\`:
- Person inspection works:
- User creation works:
- Group membership change works:
- Break-glass accounts avoided:
- Notes:

## Service results

### Files / Copyparty

- URL: \`https://${files_domain}\`
- Logged-out behavior:
- \`test-basic\` denied:
- \`test-files\` allowed:
- \`/me/<username>\` private path:
- \`/shared/exchange\` shared path:
- \`/shared/public\` shared path:
- \`/incoming/photos\` ingest path:
- \`/incoming/documents\` ingest path:
- Upload:
- Download:
- Rename:
- Delete:
- Any proxy loop or callback error:
- Notes:

### Immich

- URL: \`https://${photos_domain}\`
- \`test-basic\` denied or unusable:
- \`immich-users\` login works:
- First-login user row created:
- Photo upload works:
- Thumbnail and metadata visible:
- \`immich-admin\` admin automatic:
- \`admindsaw\` still admin:
- Notes:

### Paperless

- URL: \`https://paperless.${domain}\`
- \`test-basic\` denied or unusable:
- \`paperless-users\` login works:
- First-login user row created or linked:
- Document upload works:
- Document processing behaves normally:
- \`paperless-admin\` admin automatic:
- Local recovery superuser still present:
- Notes:

### Audiobookshelf

- URL: \`https://${audiobooks_domain}/audiobookshelf/\`
- \`test-basic\` denied or unusable:
- \`audiobookshelf-users\` login works:
- First-login user row created or linked:
- OIDC redirect path works:
- \`audiobookshelf-admin\` admin automatic:
- \`admindsaw\` root bootstrap still works:
- Playback or browse test:
- Notes:

### Kavita

- URL: \`https://${kavita_domain}\`
- \`test-basic\` denied or unusable:
- \`kavita-login\` login works:
- First-login user row created:
- \`kavita-admin\` admin automatic:
- Browse or open works:
- Admin library-management test:
- Notes:

### Jellyfin

- URL: \`https://${jellyfin_domain}\`
- Local admin login:
- Local user login:
- Browse or playback test:
- Notes:

### Jellyseerr

- URL: \`https://${jellyseerr_domain}\`
- Public settings show \`applicationUrl=https://${jellyseerr_domain}\`:
- Internal Jellyfin target is \`127.0.0.1:8096\`:
- Jellyfin-backed sign-in:
- Request creation:
- Admin or settings access:
- Notes:

### SMB over NetBird

- SMB only reachable on NetBird:
- \`homes\` share works:
- \`exchange\` share works:
- \`public\` share works:
- \`photos-upload\` share works:
- \`documents-upload\` share works:
- Notes:

## Access-control regression summary

| Service | \`users\` only denied | Wrong app group denied | Login group works | Admin group works | Admin needed local follow-up | Notes |
|---|---:|---:|---:|---:|---:|---|
| Files / Copyparty |  |  |  |  | n/a |  |
| Immich |  |  |  |  |  |  |
| Paperless |  |  |  |  |  |  |
| Audiobookshelf |  |  |  |  |  |  |
| Kavita |  |  |  |  |  |  |
| Jellyfin | n/a | n/a | n/a | n/a | n/a |  |
| Jellyseerr | n/a | n/a | n/a | n/a | n/a |  |

## Storage and write-path validation

- Copyparty workspace root: \`/mnt/data/workspaces\`
- Immich managed path: \`/mnt/data/media/photos/managed\`
- Immich external path: \`/mnt/data/media/photos/external\`
- Paperless consume path: \`/mnt/data/media/documents/consume\`
- Paperless archive path: \`/mnt/data/media/documents/archive\`
- Paperless export path: \`/mnt/data/media/documents/export\`
- Audiobookshelf appdata path: \`/mnt/data/appdata/audiobookshelf\`
- Kavita appdata path: \`/mnt/data/appdata/kavita\`
- Jellyfin appdata path: \`/mnt/data/appdata/jellyfin/server\`
- Any permission anomaly:
- Any unexpected \`snapraid diff\` entries:

## Cleanup

- Temporary Kanidm users removed:
- Temporary app-local content removed:
- Persistent local rows intentionally left behind:
- Apps needing app-local admin promotion:
- Follow-up documentation updates needed:

## Final outcome

- Overall status:
- Blockers:
- Residual risk:
- Next action:
EOF
