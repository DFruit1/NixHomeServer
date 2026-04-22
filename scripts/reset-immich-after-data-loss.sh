#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

usage() {
  cat <<'EOF'
Usage: scripts/reset-immich-after-data-loss.sh [--print-only|--yes]

Reset the SSD-backed Immich PostgreSQL database after the ZFS media pool has
been recreated without restoring the original media contents.
EOF
}

need() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "❌ Missing required tool: $tool" >&2
      exit 1
    fi
  done
}

nix_json() {
  local expr="$1"
  nix eval --json --impure --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      lib = flake.inputs.nixpkgs.lib;
      vars = import ${repo_root}/vars.nix { inherit lib; };
      cfg = (builtins.getAttr vars.hostname flake.nixosConfigurations).config;
    in
      ${expr}
  "
}

print_only=false
run_now=false
case "${1:-}" in
  "")
    print_only=true
    ;;
  --print-only)
    print_only=true
    ;;
  --yes)
    run_now=true
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

need nix jq

config_json="$(
  nix_json '{
    databaseName = cfg.services.immich.database.name;
    databaseUser = cfg.services.immich.database.user;
    mediaLocation = cfg.services.immich.mediaLocation;
    enableVectors = cfg.services.immich.database.enableVectors;
    enableVectorChord = cfg.services.immich.database.enableVectorChord;
  }'
)"

db_name="$(jq -r '.databaseName' <<<"$config_json")"
db_user="$(jq -r '.databaseUser' <<<"$config_json")"
media_location="$(jq -r '.mediaLocation' <<<"$config_json")"
enable_vectors="$(jq -r '.enableVectors' <<<"$config_json")"
enable_vectorchord="$(jq -r '.enableVectorChord' <<<"$config_json")"

extensions=(
  "unaccent"
  "uuid-ossp"
  "cube"
  "earthdistance"
  "pg_trgm"
)

if [[ "$enable_vectors" == "true" ]]; then
  extensions+=("vectors")
fi

if [[ "$enable_vectorchord" == "true" ]]; then
  extensions+=("vector" "vchord")
fi

sql_file="$(mktemp)"
trap 'rm -f "$sql_file"' EXIT

{
  for extension in "${extensions[@]}"; do
    printf 'CREATE EXTENSION IF NOT EXISTS "%s";\n' "$extension"
  done
  for extension in "${extensions[@]}"; do
    printf 'ALTER EXTENSION "%s" UPDATE;\n' "$extension"
  done
  printf 'ALTER SCHEMA public OWNER TO %s;\n' "$db_user"
  if [[ "$enable_vectors" == "true" ]]; then
    printf 'ALTER SCHEMA vectors OWNER TO %s;\n' "$db_user"
    printf 'GRANT SELECT ON TABLE pg_vector_index_stat TO %s;\n' "$db_user"
  fi
} >"$sql_file"

echo "operation: reset Immich database after data loss"
echo "database: ${db_name}"
echo "database owner: ${db_user}"
echo "media location: ${media_location}"
echo
echo "This drops and recreates the Immich PostgreSQL database so SSD-backed"
echo "metadata no longer points at deleted pool-backed media files."
echo
echo "Commands to be run:"
echo "  sudo systemctl stop immich-server.service immich-machine-learning.service"
echo "  sudo systemctl start postgresql.service"
echo "  sudo -u postgres dropdb --if-exists ${db_name}"
echo "  sudo -u postgres createdb --owner ${db_user} ${db_name}"
echo "  sudo -u postgres psql -v ON_ERROR_STOP=1 -d ${db_name} -f ${sql_file}"
echo "  sudo systemctl start immich-server.service immich-machine-learning.service"

if [[ "$print_only" == true ]]; then
  exit 0
fi

if [[ "$run_now" != true ]]; then
  exit 1
fi

need sudo systemctl

sudo systemctl stop immich-server.service immich-machine-learning.service
sudo systemctl start postgresql.service
sudo -u postgres dropdb --if-exists "$db_name"
sudo -u postgres createdb --owner "$db_user" "$db_name"
sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$db_name" -f "$sql_file"
sudo systemctl start immich-server.service immich-machine-learning.service
