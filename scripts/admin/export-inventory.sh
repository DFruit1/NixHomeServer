#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/admin/export-inventory.sh [--host <flake-hostname>] [--format json|text]

Export evaluated operations inventory for automation, documentation, and
runtime checks without changing the system.
EOF
}

host=""
format="json"
while (($# > 0)); do
  case "$1" in
    --host)
      host="${2:-}"
      shift 2
      ;;
    --format)
      format="${2:-}"
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

case "$format" in
  json|text)
    ;;
  *)
    echo "blocked: --format must be json or text" >&2
    exit 1
    ;;
esac

if [[ -n "${NIXHOMESERVER_INVENTORY_JSON_FILE:-}" ]]; then
  inventory_json="$(< "$NIXHOMESERVER_INVENTORY_JSON_FILE")"
elif [[ -n "${NIXHOMESERVER_INVENTORY_JSON:-}" ]]; then
  inventory_json="$NIXHOMESERVER_INVENTORY_JSON"
else
  if [[ -z "$host" ]]; then
    host="$(default_host)"
  fi

  inventory_json="$(inventory_json_for_host "$host")"
fi

if [[ "$format" == "json" ]]; then
  jq -c . <<<"$inventory_json"
  exit 0
fi

echo "NixHomeServer operations inventory"
echo "host: $(jq -r '.host' <<<"$inventory_json")"
echo "schema: $(jq -r '.schemaVersion' <<<"$inventory_json")"
echo

echo "Network"
echo "  domain: $(jq -r '.settings.domain' <<<"$inventory_json")"
echo "  DNS mode: $(jq -r '.settings.dnsMode' <<<"$inventory_json")"
echo "  Caddy hosts: $(jq '.network.caddyHosts | length' <<<"$inventory_json")"
echo "  Cloudflare ingress hosts: $(jq '.network.cloudflaredHosts | length' <<<"$inventory_json")"
echo

echo "Identity"
echo "  Kanidm groups: $(jq '.identity.kanidmGroups | length' <<<"$inventory_json")"
echo "  OAuth clients: $(jq '.identity.oauthClients | length' <<<"$inventory_json")"
echo "  auth mode: $(jq -r '.identity.authGateway.mode' <<<"$inventory_json")"
echo

echo "Storage"
echo "  profile: $(jq -r '.storage.profile' <<<"$inventory_json")"
echo "  root filesystem: $(jq -r '.storage.rootFsType' <<<"$inventory_json")"
echo "  requires ZFS: $(jq -r '.storage.requiresZfs' <<<"$inventory_json")"
echo "  data root: $(jq -r '.storage.dataRoot' <<<"$inventory_json")"
echo "  data root is mountpoint: $(jq -r '.storage.dataRootIsMountPoint' <<<"$inventory_json")"
echo "  users root: $(jq -r '.storage.usersRoot' <<<"$inventory_json")"
echo "  shared root: $(jq -r '.storage.sharedRoot' <<<"$inventory_json")"
echo "  backup root: $(jq -r '.storage.backupRoot' <<<"$inventory_json")"
echo "  ZFS snapshot policy: $(jq -c '.storage.zfsSnapshotPolicy' <<<"$inventory_json")"
echo

echo "Backups"
echo "  app state entries: $(jq '.backups.appStateEntries | length' <<<"$inventory_json")"
echo "  critical paths: $(jq '.backups.criticalPaths | length' <<<"$inventory_json")"
echo "  snapshot roots: $(jq -r '.backups.snapshotRoots | join(", ")' <<<"$inventory_json")"
echo "  Kopia repository: $(jq -r '.backups.repositoryPath' <<<"$inventory_json")"
echo "  path inventories: $(jq '.backups.pathInventories | length' <<<"$inventory_json")"
echo "  SQLite dumps: $(jq '.backups.sqliteDumps | length' <<<"$inventory_json")"
echo "  PostgreSQL dumps: $(jq '.backups.postgresqlDumps | length' <<<"$inventory_json")"
echo

echo "Impermanence"
echo "  directories: $(jq '.impermanence.directories | length' <<<"$inventory_json")"
echo "  files: $(jq '.impermanence.files | length' <<<"$inventory_json")"
echo

echo "Secrets"
echo "  age secrets: $(jq '.secrets.ageSecretNames | length' <<<"$inventory_json")"
echo "  required external secrets: $(jq '.secrets.requiredExternalSecretNames | length' <<<"$inventory_json")"
echo "  optional external secrets: $(jq '.secrets.optionalExternalSecretNames | length' <<<"$inventory_json")"
echo

echo "Systemd"
echo "  services: $(jq '.systemd.serviceNames | length' <<<"$inventory_json")"
