#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/admin/doctor.sh [--host <site-or-hostname>]

Validate first-install readiness without changing the system.
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

echo "NixHomeServer install doctor"
echo "host: ${host}"
echo

need bash git jq nix rg ssh
if ((status_blocked > 0)); then
  finish_report
fi

if nix eval --raw ".#nixosConfigurations.${host}.config.system.name" >/dev/null 2>&1; then
  ready "flake host '${host}' evaluates"
else
  block "flake host '${host}' does not evaluate"
  finish_report
fi

settings_json="$(nix_json_for_host "$host" "removeAttrs cfg.nixhomeserver.settings [ \"kanidmIssuer\" \"kanidmDiscoveryUrl\" ]")"
apps_json="$(nix_json_for_host "$host" "cfg.nixhomeserver.apps")"
external_secrets_json="$(nix eval --json --impure --expr "builtins.attrNames ((import ${repo_root}/secrets/manifest.nix).externalSecrets)")"

domain="$(jq -r '.domain' <<<"$settings_json")"
admin_user="$(jq -r '.kanidmAdminUser' <<<"$settings_json")"
ssh_key="$(jq -r '.serverSSHPubKey' <<<"$settings_json")"
lan_iface="$(jq -r '.netIface' <<<"$settings_json")"
lan_ip="$(jq -r '.serverLanIP' <<<"$settings_json")"
dns_mode="$(jq -r '.dnsMode' <<<"$settings_json")"
main_disk="$(jq -r '.mainDisk' <<<"$settings_json")"
cloudflare_tunnel="$(jq -r '.cloudflareTunnelName' <<<"$settings_json")"

case "$domain" in
  example.test|example.*|*CHANGE_ME*)
    block "vars.nix -> network.domain is still a template value: ${domain}"
    ;;
  *)
    ready "vars.nix -> network.domain is set to ${domain}"
    ;;
esac

if [[ "$admin_user" == *CHANGE_ME* || -z "$admin_user" ]]; then
  block "vars.nix -> identity.adminUser is not set"
else
  ready "vars.nix -> identity.adminUser is ${admin_user}"
fi

if [[ "$ssh_key" =~ ^ssh-(ed25519|rsa|ecdsa)[[:space:]] ]]; then
  if [[ "$ssh_key" == *CHANGE_ME* ]]; then
    block "vars.nix -> identity.sshPublicKey is still a placeholder"
  else
    ready "vars.nix -> identity.sshPublicKey is present"
  fi
else
  block "vars.nix -> identity.sshPublicKey does not look like an SSH public key"
fi

case "$dns_mode" in
  split-horizon|netbird-only)
    ready "vars.nix -> dnsSettings.mode is ${dns_mode}"
    ;;
  *)
    block "vars.nix -> dnsSettings.mode must be split-horizon or netbird-only, got ${dns_mode}"
    ;;
esac

if ip link show "$lan_iface" >/dev/null 2>&1; then
  ready "vars.nix -> network.lanInterface exists locally: ${lan_iface}"
else
  warn "vars.nix -> network.lanInterface '${lan_iface}' is not present on this workstation; verify it on the target server"
fi

if [[ "$lan_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  ready "vars.nix -> network.lanIp is shaped correctly: ${lan_ip}"
else
  block "vars.nix -> network.lanIp is invalid: ${lan_ip}"
fi

if [[ "$main_disk" == *CHANGE_ME* ]]; then
  block "vars.nix -> storage.systemDisk is still a placeholder"
elif [[ -e "/dev/disk/by-id/${main_disk}" ]]; then
  ready "vars.nix -> storage.systemDisk exists locally: /dev/disk/by-id/${main_disk}"
else
  warn "vars.nix -> storage.systemDisk /dev/disk/by-id/${main_disk} is not present locally; verify it from the installer or target host"
fi

while IFS= read -r disk_id; do
  [[ -n "$disk_id" ]] || continue
  if [[ "$disk_id" == *CHANGE_ME* ]]; then
    block "vars.nix -> storage.dataPool.mirrorPairs contains a placeholder: ${disk_id}"
  elif [[ -e "/dev/disk/by-id/${disk_id}" ]]; then
    ready "vars.nix -> storage.dataPool disk exists locally: /dev/disk/by-id/${disk_id}"
  else
    warn "vars.nix -> storage.dataPool disk /dev/disk/by-id/${disk_id} is not present locally; verify it from the installer or target host"
  fi
done < <(jq -r '.zfsDataPoolDiskIds[]' <<<"$settings_json")

port_duplicates="$(jq -r '.networking.ports | to_entries | map(select(.key | endswith("Container") | not)) | group_by(.value)[] | select(length > 1) | map(.key + "=" + (.value|tostring)) | join(", ")' <<<"$settings_json")"
if [[ -n "$port_duplicates" ]]; then
  block "vars.nix -> advanced.ports has duplicate assignments: ${port_duplicates}"
else
  ready "vars.nix -> advanced.ports assignments are unique"
fi

if [[ -s secrets/pubkeys/age.pub ]]; then
  ready "age public key exists at secrets/pubkeys/age.pub"
else
  block "missing age public key at secrets/pubkeys/age.pub"
fi

while IFS= read -r secret; do
  if [[ -s "secrets/${secret}.age" ]]; then
    ready "encrypted external secret exists: secrets/${secret}.age"
  elif [[ -s "secrets/top/${secret}" ]]; then
    warn "external secret is staged but not encrypted yet: secrets/top/${secret}"
  else
    block "missing external secret input: stage secrets/top/${secret} or generate secrets/${secret}.age"
  fi
done < <(jq -r '.[]' <<<"$external_secrets_json")

if [[ "$cloudflare_tunnel" == *CHANGE_ME* || -z "$cloudflare_tunnel" ]]; then
  block "vars.nix -> edge.cloudflareTunnelName is not configured"
else
  ready "vars.nix -> edge.cloudflareTunnelName is ${cloudflare_tunnel}"
fi

enabled_apps="$(jq -r '.enabledApps[]?' <<<"$settings_json" | paste -sd ',' -)"
if [[ -z "$enabled_apps" ]]; then
  enabled_apps="$(jq -r 'to_entries[] | select(.value.enable == true) | .key' <<<"$apps_json" | paste -sd ',' -)"
fi
if [[ -n "$enabled_apps" ]]; then
  ready "vars.nix -> apps enabled set: ${enabled_apps}"
else
  warn "vars.nix -> apps has no optional apps enabled"
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  untracked="$(git status --porcelain --untracked-files=all | awk '$1 == "??" {print $2}' | head -n 10)"
  if [[ -n "$untracked" ]]; then
    warn "untracked files exist; add intended new files before rebuilds: $(tr '\n' ' ' <<<"$untracked")"
  else
    ready "no untracked files are visible to git"
  fi
else
  warn "not running inside a git worktree"
fi

finish_report
