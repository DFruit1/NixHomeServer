#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/admin/render-runbook.sh --host <site-or-hostname>

Render a personalized install and operations runbook from evaluated settings.
EOF
}

host=""
while (($# > 0)); do
  case "$1" in
    --host)
      host="${2:-}"
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

if [[ -z "$host" ]]; then
  host="$(default_host)"
fi

settings_json="$(nix_json_for_host "$host" "removeAttrs cfg.nixhomeserver.settings [ \"kanidmIssuer\" \"kanidmDiscoveryUrl\" ]")"
apps_json="$(nix_json_for_host "$host" "cfg.nixhomeserver.apps")"

hostname="$(jq -r '.hostname' <<<"$settings_json")"
domain="$(jq -r '.domain' <<<"$settings_json")"
admin_user="$(jq -r '.kanidmAdminUser' <<<"$settings_json")"
admin_email="$(jq -r '.kanidmAdminEmail' <<<"$settings_json")"
local_admin_user="$(jq -r '.localAdminUser // .kanidmAdminUser' <<<"$settings_json")"
lan_ip="$(jq -r '.serverLanIP' <<<"$settings_json")"
lan_iface="$(jq -r '.netIface' <<<"$settings_json")"

cat <<EOF
# NixHomeServer Runbook: ${host}

## Install Checklist

- Hostname: \`${hostname}\`
- Domain: \`${domain}\`
- Delegated admin: \`${admin_user}\` / \`${admin_email}\`
- Local SSH/sudo admin: \`${local_admin_user}\`
- LAN interface: \`${lan_iface}\`
- LAN address: \`${lan_ip}\`
- System disk by-id: \`$(jq -r '.mainDisk' <<<"$settings_json")\`
- Data pool: \`$(jq -r '.zfsDataPool.name' <<<"$settings_json")\` mounted at \`$(jq -r '.zfsDataPool.mountPoint' <<<"$settings_json")\`

## Required External Secrets

Stage these files under \`secrets/top/\`, then run \`./scripts/generate-all-secrets.sh\`:

- \`netbirdSetupKey\`
- \`cfHomeCreds\`
- \`cfAPIToken\`

## Validation And Deploy

\`\`\`bash
nix run .#doctor -- --host ${host}
./scripts/deploy.sh --target "${local_admin_user}@${hostname}" --build-host "${local_admin_user}@${hostname}" --action test --hostname ${hostname}
./scripts/deploy.sh --target "${local_admin_user}@${hostname}" --build-host "${local_admin_user}@${hostname}" --action switch --hostname ${hostname}
./scripts/deploy.sh --target "${local_admin_user}@${hostname}" --build-host "${local_admin_user}@${hostname}" --action test --hostname ${hostname} --debug
ssh "${local_admin_user}@${hostname}" 'cd /path/to/repo && sudo systemctl --failed --no-pager'
\`\`\`

## App URLs

EOF

jq -r '
  to_entries[]
  | select(.value.enable == true)
  | "- `" + .key + "`"
' <<<"$apps_json"

cat <<EOF

Core URLs:

- Identity: \`https://$(jq -r '.kanidmDomain' <<<"$settings_json")\`
- Files: \`https://$(jq -r '.filesDomain' <<<"$settings_json")\`
- Uploads: \`https://$(jq -r '.uploadsDomain' <<<"$settings_json")\`

## User Onboarding

\`\`\`bash
kanidm-admin
kanidm-admin user create NEW_USER --display-name "New User" --email "new.user@${domain}"
kanidm-admin membership add NEW_USER users
kanidm-admin membership add NEW_USER user-files
\`\`\`

Grant app-specific groups only when the user needs that app. Use \`app-admin\` only for application operators.

## Recovery Pointers

- Failed units: \`sudo systemctl --failed --no-pager\`
- Data mirror status: \`sudo zpool status $(jq -r '.zfsDataPool.name' <<<"$settings_json")\`
- SMART short test sweep: \`sudo systemctl start storage-smart-short.service\`
- Backup target selection: \`manage-backup-target list\`
- System-state restore: see \`documentation/restore-and-recovery.md\`
EOF
