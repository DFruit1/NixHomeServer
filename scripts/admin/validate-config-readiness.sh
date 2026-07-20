#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/admin/validate-config-readiness.sh [--host <flake-hostname>] [--identity <age-key>]
       [--require-local-hardware] [--allow-host-platform-mismatch]
       [--allow-unverified-secrets]

Validate evaluated settings, required secrets, and local bootstrap/deploy
preconditions without changing the system.
EOF
}

host=""
identity_file=""
require_local_hardware=0
allow_unverified_secrets=0
allow_host_platform_mismatch=0
while (($# > 0)); do
  case "$1" in
    --host)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "blocked: --host requires a flake hostname" >&2; exit 1; }
      host="${2:-}"
      shift 2
      ;;
    --identity)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "blocked: --identity requires a path" >&2; exit 1; }
      identity_file="${2:-}"
      shift 2
      ;;
    --require-local-hardware)
      require_local_hardware=1
      shift
      ;;
    --allow-host-platform-mismatch)
      allow_host_platform_mismatch=1
      shift
      ;;
    --allow-unverified-secrets)
      allow_unverified_secrets=1
      shift
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
if ! validate_flake_host_name "$host"; then
  echo "blocked: --host must be one DNS hostname label (letters, digits, and interior hyphens)" >&2
  exit 1
fi

echo "NixHomeServer config readiness validation"
echo "host: ${host}"
echo

need age age-keygen awk bash find git ip jq mktemp nix paste python3 readlink rg sed ssh ssh-keygen tr uname
if ((status_blocked > 0)); then
  finish_report
fi

readiness_tmpdir="$(mktemp -d)"
cleanup_readiness_tmpdir() { rm -rf "$readiness_tmpdir"; }
trap cleanup_readiness_tmpdir EXIT
nix_eval_log="$readiness_tmpdir/nix-eval.log"
source "$repo_root/scripts/helpers/secrets-common.sh"
load_manifest_json
external_specs="$(manifest_external_specs)"
declare -A external_secret_validators=()
while IFS=$'\t' read -r external_name validator_name _required; do
  [[ -n "$external_name" ]] || continue
  external_secret_validators[$external_name]="$(validator_function "$validator_name")"
done <<<"$external_specs"

if nix eval --raw ".#nixosConfigurations.${host}.config.system.build.toplevel.drvPath" \
  >/dev/null 2>"$nix_eval_log"; then
  ready "complete NixOS closure for flake host '${host}' evaluates"
else
  block "complete NixOS closure for flake host '${host}' does not evaluate"
  echo "Nix evaluation details:" >&2
  sed 's/^/  /' "$nix_eval_log" >&2
  finish_report
fi

settings_json="$(nix_json_for_host "$host" "removeAttrs (builtins.getAttr hostName flake.lib.nixhomeserverSettings) [ \"kanidmIssuer\" \"kanidmDiscoveryUrl\" ]")"
caddy_hosts_json="$(nix_json_for_host "$host" "builtins.attrNames cfg.services.caddy.virtualHosts")"
active_secret_names_json="$(nix_json_for_host "$host" "builtins.attrNames cfg.age.secrets")"

domain="$(jq -r '.domain' <<<"$settings_json")"
admin_user="$(jq -r '.kanidmAdminUser' <<<"$settings_json")"
admin_email="$(jq -r '.kanidmAdminEmail' <<<"$settings_json")"
local_admin_user="$(jq -r '.localAdminUser' <<<"$settings_json")"
ssh_key="$(jq -r '.serverSSHPubKey' <<<"$settings_json")"
lan_iface="$(jq -r '.netIface' <<<"$settings_json")"
lan_ip="$(jq -r '.serverLanIP' <<<"$settings_json")"
lan_prefix="$(jq -r '.networking.lan.prefixLength' <<<"$settings_json")"
lan_gateway="$(jq -r '.networking.lan.gateway' <<<"$settings_json")"
netbird_ip="$(jq -r '.networking.netbird.ip' <<<"$settings_json")"
netbird_cidr="$(jq -r '.networking.netbird.cidr' <<<"$settings_json")"
dns_mode="$(jq -r '.dnsMode' <<<"$settings_json")"
main_disk="$(jq -r '.mainDisk' <<<"$settings_json")"
host_platform="$(jq -r '.hostPlatform' <<<"$settings_json")"
hardware_profile="$(jq -r '.hardwareProfile' <<<"$settings_json")"
storage_profile="$(jq -r '.storageProfile' <<<"$settings_json")"
cloudflare_tunnel="$(jq -r '.cloudflareTunnelName' <<<"$settings_json")"
host_id="$(jq -r '.hostId' <<<"$settings_json")"

case "$host_platform" in
  x86_64-linux|aarch64-linux)
    ready "vars.nix -> system.hostPlatform is ${host_platform}"
    ;;
  *)
    block "vars.nix -> system.hostPlatform must be x86_64-linux or aarch64-linux, got ${host_platform}"
    ;;
esac

if ((require_local_hardware == 1)); then
  case "$(uname -m)" in
    x86_64) local_host_platform="x86_64-linux" ;;
    aarch64|arm64) local_host_platform="aarch64-linux" ;;
    *) local_host_platform="unsupported-$(uname -m)" ;;
  esac
  if [[ "$local_host_platform" == "$host_platform" ]]; then
    ready "installer/target architecture matches system.hostPlatform: ${host_platform}"
  elif ((allow_host_platform_mismatch == 1)); then
    warn "EXPERT OVERRIDE: installer/target architecture ${local_host_platform} does not match ${host_platform}; destructive bootstrap may require a configured remote builder or emulation"
  else
    block "installer/target architecture ${local_host_platform} does not match system.hostPlatform ${host_platform}; correct vars.nix or explicitly pass --allow-host-platform-mismatch only with a working cross-build strategy"
  fi
elif ((allow_host_platform_mismatch == 1)); then
  block "--allow-host-platform-mismatch is only meaningful with --require-local-hardware"
fi

case "$hardware_profile" in
  generated|existing-server|generic-uefi)
    ready "vars.nix -> system.hardwareProfile is ${hardware_profile}"
    ;;
  *)
    block "vars.nix -> system.hardwareProfile must be generated, existing-server, or generic-uefi, got ${hardware_profile}"
    ;;
esac

if [[ "$hardware_profile" == "existing-server" && "$host_platform" != "x86_64-linux" ]]; then
  block "vars.nix -> system.hardwareProfile existing-server is only valid with x86_64-linux; generate hardware-configuration.nix and use generated for ${host_platform}"
else
  ready "vars.nix -> system.hardwareProfile is compatible with ${host_platform}"
fi

case "$storage_profile" in
  zfs-mirror|single-disk-ext4)
    ready "vars.nix -> storage.profile is ${storage_profile}"
    ;;
  *)
    block "vars.nix -> storage.profile must be zfs-mirror or single-disk-ext4, got ${storage_profile}"
    ;;
esac

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

if [[ "$admin_user" == "$local_admin_user" ]]; then
  block "vars.nix -> identity.adminUser must be separate from identity.localAdminUser (${local_admin_user})"
else
  ready "vars.nix -> identity.adminUser is separate from local admin ${local_admin_user}"
fi

mapfile -t configured_emails < <(jq -r '
  ([.kanidmAdminEmail] + (.kanidmAdminMailAddresses // []) + ((.kanidmAppUserEmails // {}) | to_entries | map(.value)))
  | unique[]
' <<<"$settings_json")
for configured_email in "${configured_emails[@]}"; do
  if [[ "$configured_email" == *CHANGE_ME* \
    || "$configured_email" == *@example.* \
    || "$configured_email" == *.test ]]; then
    block "vars.nix -> identity email is still a reserved/template value: ${configured_email}"
  elif [[ ! "$configured_email" =~ ^[A-Za-z0-9][A-Za-z0-9._%+-]*@[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    block "vars.nix -> identity email is not a valid user@public-domain address: ${configured_email}"
  else
    ready "vars.nix -> identity email is configured: ${configured_email}"
  fi
done

ssh_key_file="$readiness_tmpdir/server-ssh-key.pub"
: >"$ssh_key_file"
chmod 0600 "$ssh_key_file"
if [[ "$ssh_key" == *CHANGE_ME* ]]; then
  block "vars.nix -> identity.sshPublicKey is still a placeholder"
elif [[ "$ssh_key" == *$'\n'* || "$ssh_key" == *$'\r'* ]]; then
  block "vars.nix -> identity.sshPublicKey must contain exactly one public-key line"
elif ! printf '%s\n' "$ssh_key" >"$ssh_key_file" \
  || ! ssh-keygen -l -f "$ssh_key_file" >/dev/null 2>&1; then
  block "vars.nix -> identity.sshPublicKey is not a valid OpenSSH public key"
else
  ready "vars.nix -> identity.sshPublicKey is a valid OpenSSH public key"
fi
rm -f "$ssh_key_file"

case "$dns_mode" in
  split-horizon|netbird-only)
    ready "vars.nix -> dnsSettings.mode is ${dns_mode}"
    ;;
  *)
    block "vars.nix -> dnsSettings.mode must be split-horizon or netbird-only, got ${dns_mode}"
    ;;
esac

lan_iface_exists=0
if ip link show "$lan_iface" >/dev/null 2>&1; then
  lan_iface_exists=1
  ready "vars.nix -> network.lanInterface exists locally: ${lan_iface}"
elif ((require_local_hardware == 1)); then
  block "vars.nix -> network.lanInterface '${lan_iface}' is absent on this installer/target host"
else
  warn "vars.nix -> network.lanInterface '${lan_iface}' is not present on this workstation; verify it on the target server"
fi

if ((require_local_hardware == 1 && lan_iface_exists == 1)); then
  carrier_path="/sys/class/net/${lan_iface}/carrier"
  if [[ -r "$carrier_path" && "$(<"$carrier_path")" == "1" ]]; then
    ready "target LAN interface has carrier: ${lan_iface}"
  elif [[ -r "$carrier_path" ]]; then
    block "target LAN interface has no carrier: ${lan_iface}; connect the intended cable/switch port before installation"
  else
    warn "could not read carrier state for target LAN interface ${lan_iface}"
  fi

  if ip route get "$lan_gateway" oif "$lan_iface" >/dev/null 2>&1; then
    ready "installer can route to the configured LAN gateway through ${lan_iface}"
  else
    block "installer has no route to configured gateway ${lan_gateway} through ${lan_iface}"
  fi

  if ip -4 -o address show dev "$lan_iface" | awk '{print $4}' | awk -F/ -v ip="$lan_ip" '$1 == ip { found=1 } END { exit !found }'; then
    ready "configured LAN address is already assigned locally to ${lan_iface}; a peer-conflict probe is still required"
  fi
  if [[ "$EUID" -eq 0 ]] && command -v arping >/dev/null 2>&1; then
    arping_log="$readiness_tmpdir/arping-duplicate.log"
    if arping -D -q -c 2 -w 3 -I "$lan_iface" "$lan_ip" >"$arping_log" 2>&1; then
      ready "no host answered duplicate-address probes for ${lan_ip} on ${lan_iface}"
    else
      block "configured LAN address ${lan_ip} appears to be in use on ${lan_iface}; inspect with arping before installation"
      sed 's/^/  /' "$arping_log" >&2
    fi
  else
    warn "duplicate-address probing for ${lan_ip} was skipped; rerun readiness as root with arping available before destructive bootstrap"
  fi
fi

if network_error="$(python3 - "$lan_ip" "$lan_prefix" "$lan_gateway" "$netbird_ip" "$netbird_cidr" <<'PY'
import ipaddress
import sys

try:
    lan_ip = ipaddress.IPv4Address(sys.argv[1])
    prefix = int(sys.argv[2])
    if not 1 <= prefix <= 30:
        raise ValueError("LAN prefix must be between 1 and 30")
    lan_network = ipaddress.IPv4Network(f"{lan_ip}/{prefix}", strict=False)
    gateway = ipaddress.IPv4Address(sys.argv[3])
    netbird_ip = ipaddress.IPv4Address(sys.argv[4])
    netbird_network = ipaddress.IPv4Network(sys.argv[5], strict=True)
    if lan_ip in (lan_network.network_address, lan_network.broadcast_address):
        raise ValueError("LAN IP cannot be the subnet network or broadcast address")
    if gateway not in lan_network or gateway in (lan_network.network_address, lan_network.broadcast_address):
        raise ValueError("LAN gateway must be a usable address in the configured LAN subnet")
    if lan_ip == gateway:
        raise ValueError("LAN IP must not equal the LAN gateway")
    if netbird_ip not in netbird_network:
        raise ValueError("NetBird IP must belong to network.netbirdCidr")
except (ValueError, ipaddress.AddressValueError, ipaddress.NetmaskValueError) as error:
    print(error)
    raise SystemExit(1)
PY
)"; then
  ready "LAN and NetBird addresses, prefixes, and gateway are valid and internally consistent"
else
  block "vars.nix -> network addressing is invalid: ${network_error}"
fi

if [[ ! "$host_id" =~ ^[0-9a-f]{8}$ ]]; then
  block "vars.nix -> system.hostId must be an 8-character lowercase hexadecimal value"
elif [[ "$host_id" == "00000000" && "$storage_profile" == "zfs-mirror" ]]; then
  block "vars.nix -> system.hostId must be non-placeholder for zfs-mirror"
elif [[ "$host_id" == "00000000" ]]; then
  warn "vars.nix -> system.hostId is still 00000000; acceptable for single-disk-ext4, but set a stable value before switching to ZFS"
else
  ready "vars.nix -> system.hostId is set"
fi

if [[ "$main_disk" == *CHANGE_ME* ]]; then
  block "vars.nix -> storage.systemDisk is still a placeholder"
elif [[ -e "/dev/disk/by-id/${main_disk}" ]]; then
  ready "vars.nix -> storage.systemDisk exists locally: /dev/disk/by-id/${main_disk}"
elif ((require_local_hardware == 1)); then
  block "vars.nix -> storage.systemDisk is absent on this installer/target host: /dev/disk/by-id/${main_disk}"
else
  warn "vars.nix -> storage.systemDisk /dev/disk/by-id/${main_disk} is not present locally; verify it from the installer or target host"
fi

if [[ "$storage_profile" == "zfs-mirror" ]]; then
  while IFS= read -r disk_id; do
    [[ -n "$disk_id" ]] || continue
    if [[ "$disk_id" == *CHANGE_ME* ]]; then
      block "vars.nix -> storage.dataPool.mirrorPairs contains a placeholder: ${disk_id}"
    elif [[ -e "/dev/disk/by-id/${disk_id}" ]]; then
      ready "vars.nix -> storage.dataPool disk exists locally: /dev/disk/by-id/${disk_id}"
    elif ((require_local_hardware == 1)); then
      block "vars.nix -> storage.dataPool disk is absent on this installer/target host: /dev/disk/by-id/${disk_id}"
    else
      warn "vars.nix -> storage.dataPool disk /dev/disk/by-id/${disk_id} is not present locally; verify it from the installer or target host"
    fi
  done < <(jq -r '.zfsDataPoolDiskIds[]' <<<"$settings_json")

  invalid_pair_count="$(jq '[.zfsDataPool.mirrorPairs[] | select((type != "array") or (length != 2))] | length' <<<"$settings_json")"
  if [[ "$invalid_pair_count" != "0" ]]; then
    block "vars.nix -> every storage.dataPool.mirrorPairs entry must contain exactly two disks"
  else
    ready "vars.nix -> every ZFS mirror contains exactly two disks"
  fi

  duplicate_disk_ids="$(jq -r '[.mainDisk] + .zfsDataPoolDiskIds | sort | group_by(.)[] | select(length > 1) | .[0]' <<<"$settings_json")"
  if [[ -n "$duplicate_disk_ids" ]]; then
    block "vars.nix -> system and data disks must be unique; repeated IDs: $(paste -sd ',' <<<"$duplicate_disk_ids")"
  else
    ready "vars.nix -> system and data disk IDs are unique"
  fi

  declare -A physical_disks=()
  while IFS= read -r disk_id; do
    disk_path="/dev/disk/by-id/${disk_id}"
    [[ -e "$disk_path" ]] || continue
    canonical_disk="$(readlink -f "$disk_path")"
    if [[ -n "${physical_disks[$canonical_disk]:-}" ]]; then
      block "vars.nix -> ${disk_id} and ${physical_disks[$canonical_disk]} are aliases for the same physical disk ${canonical_disk}"
    else
      physical_disks[$canonical_disk]="$disk_id"
    fi
  done < <(jq -r '[.mainDisk] + .zfsDataPoolDiskIds | .[]' <<<"$settings_json")
else
  ready "storage.profile single-disk-ext4 does not require ZFS data disks"
fi

port_duplicates="$(jq -r '.networking.ports | to_entries | map(select(.key | endswith("Container") | not)) | group_by(.value)[] | select(length > 1) | map(.key + "=" + (.value|tostring)) | join(", ")' <<<"$settings_json")"
if [[ -n "$port_duplicates" ]]; then
  block "vars.nix -> advanced.ports has duplicate assignments: ${port_duplicates}"
else
  ready "vars.nix -> advanced.ports assignments are unique"
fi

if [[ -s secrets/pubkeys/age.pub ]] && [[ "$(tr -d '\r\n' <secrets/pubkeys/age.pub)" =~ ^age1[023456789acdefghjklmnpqrstuvwxyz]+$ ]]; then
  ready "age public key exists at secrets/pubkeys/age.pub"
else
  block "missing or invalid age public key at secrets/pubkeys/age.pub"
fi

if ! plaintext_staging_is_empty "$repo_root/secrets/unencrypted"; then
  block "plaintext staging directory is not empty; move secrets to a vault or remove secrets/unencrypted before copying or installing this repository"
else
  ready "plaintext staging directory is empty or absent"
fi

identity_matches=0
if [[ -n "$identity_file" ]]; then
  if [[ ! -r "$identity_file" || ! -f "$identity_file" ]]; then
    block "age identity is not a readable regular file: ${identity_file}"
  elif [[ "$(age-keygen -y "$identity_file" 2>/dev/null | tr -d '\r\n')" != "$(tr -d '\r\n' <secrets/pubkeys/age.pub)" ]]; then
    block "age identity ${identity_file} does not match secrets/pubkeys/age.pub"
  else
    identity_matches=1
    ready "age identity matches secrets/pubkeys/age.pub"
  fi
fi

active_secret_names="$(jq -r '.[]' <<<"$active_secret_names_json")"
while IFS= read -r secret; do
  [[ -n "$secret" ]] || continue
  age_file="secrets/${secret}.age"
  if [[ -s "$age_file" && -f "$age_file" && ! -L "$age_file" ]]; then
    if ((identity_matches == 1)); then
      clear_file="$readiness_tmpdir/${secret}.clear"
      if ! age --decrypt --identity "$identity_file" --output "$clear_file" "$age_file" >/dev/null 2>&1; then
        block "encrypted manifest secret does not decrypt with ${identity_file}: ${age_file}"
      elif [[ -n "${external_secret_validators[$secret]:-}" ]] \
        && ! "${external_secret_validators[$secret]}" "$clear_file"; then
        block "encrypted external secret fails its manifest validator: ${age_file}"
      else
        ready "encrypted manifest secret decrypts and validates: ${age_file}"
      fi
      rm -f "$clear_file"
    else
      ready "encrypted manifest secret exists: ${age_file}"
    fi
  elif [[ -e "$age_file" || -L "$age_file" ]]; then
    block "manifest ciphertext is empty, non-regular, or symlinked: ${age_file}"
  elif [[ -s "secrets/unencrypted/${secret}" ]]; then
    block "manifest secret is staged but not encrypted yet: secrets/unencrypted/${secret}"
  else
    block "missing manifest secret: generate secrets/${secret}.age"
  fi
done <<<"$active_secret_names"

if [[ -z "$identity_file" ]]; then
  if ((allow_unverified_secrets == 1)); then
    warn "secret decryptability was not tested because --allow-unverified-secrets was supplied"
  else
    block "secret decryptability was not tested; supply --identity <age-key> (or explicitly use --allow-unverified-secrets for inspection only)"
  fi
fi

if [[ "$cloudflare_tunnel" == *CHANGE_ME* || -z "$cloudflare_tunnel" ]]; then
  block "vars.nix -> edge.cloudflareTunnelName is not configured"
else
  ready "vars.nix -> edge.cloudflareTunnelName is ${cloudflare_tunnel}"
fi

app_hosts="$(jq -r '.[] | select(. != "'"$domain"'" and . != "www.'"$domain"'" and . != "id.'"$domain"'")' <<<"$caddy_hosts_json" | paste -sd ',' -)"
if [[ -n "$app_hosts" ]]; then
  ready "enabled app modules publish app hosts: ${app_hosts}"
else
  warn "enabled app modules publish no app Caddy hosts"
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_author_name="$(git config --local --get user.name 2>/dev/null || true)"
  git_author_email="$(git config --local --get user.email 2>/dev/null || true)"
  if [[ "$git_author_name" =~ [^[:space:]] && "$git_author_email" =~ [^[:space:]] ]]; then
    ready "repository-local Git author identity is configured: ${git_author_name} <${git_author_email}>"
  elif ((require_local_hardware == 1)); then
    block "repository-local Git author identity is incomplete; before recording target hardware, run: git config --local user.name '${admin_user}' && git config --local user.email '${admin_email}'"
  else
    warn "repository-local Git author identity is incomplete; configure git config --local user.name and user.email before the next required commit"
  fi

  git_status="$(git status --porcelain=v1 --untracked-files=all)"
  if [[ -n "$git_status" ]]; then
    worktree_preview="$(awk 'NR <= 10 { printf "%s%s", separator, $0; separator=" | " }' <<<"$git_status")"
    if ((require_local_hardware == 1)); then
      block "repository worktree is not clean; commit or remove every staged, unstaged, and untracked change before destructive bootstrap: ${worktree_preview}"
    else
      warn "repository worktree has staged, unstaged, or untracked changes; commit intended configuration before bootstrap or deploy: ${worktree_preview}"
    fi
  else
    ready "repository worktree is clean"
  fi
else
  if ((require_local_hardware == 1)); then
    block "not running inside a Git worktree; target hardware and storage identity changes must be committed before installation"
  else
    warn "not running inside a git worktree"
  fi
fi

finish_report
