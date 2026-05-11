#!/usr/bin/env bash

set -euo pipefail
umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/helpers/repo-common.sh"
source "$script_dir/helpers/runtime-health-common.sh"
init_repo_root "RUNTIME_READINESS_REPO_ROOT"
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/bootstrap-access-canaries.sh

Create or refresh the runtime access canary passwords through Kanidm reset
tokens, then warm the expected application logins and write bootstrap state.
EOF
}

while (($# > 0)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if (( EUID != 0 )); then
  echo "❌ bootstrap-access-canaries.sh must run as root." >&2
  exit 1
fi

need jq mktemp awk sed date nix
runtime_health_load_snapshot

bootstrap_state_file="$(runtime_health_snapshot_query '.accessChecks.bootstrapStateFile' | jq -r '.')"
bootstrap_state_dir="$(dirname "$bootstrap_state_file")"
browser_helper_path="$(runtime_health_snapshot_query '.accessChecks.browserHelper' | jq -r '.')"
browser_helper_abs="$repo_root/$browser_helper_path"
kanidm_url="$(runtime_health_snapshot_query '.services.edgeHttp[] | select(.name == "kanidm") | .url' | jq -r 'sub("/$"; "")')"
playwright_module="$(nix eval --raw nixpkgs#playwright-driver.outPath)/index.mjs"

if [[ ! -f "$browser_helper_abs" ]]; then
  echo "❌ Browser helper missing: $browser_helper_abs" >&2
  exit 1
fi

if [[ ! -r /run/agenix/kanidmAdminPass ]]; then
  echo "❌ Missing /run/agenix/kanidmAdminPass on this host." >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
kanidm_home="${tmpdir}/kanidm-home"
reset_tokens_file="${tmpdir}/reset-tokens.json"
helper_output_file="${tmpdir}/bootstrap-output.json"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$kanidm_home"
install -d -m 700 "$bootstrap_state_dir"
printf '[]\n' >"$reset_tokens_file"

export HOME="$kanidm_home"
export KANIDM_PASSWORD
KANIDM_PASSWORD="$(< /run/agenix/kanidmAdminPass)"

kanidm_cli() {
  nix shell nixpkgs#kanidm_1_9 -c kanidm "$@"
}

echo "ℹ️ Logging into Kanidm as idm_admin for canary bootstrap..."
kanidm_cli login -H "$kanidm_url" -D idm_admin >/dev/null

while IFS= read -r canary_json; do
  [[ -n "$canary_json" ]] || continue

  account_id="$(jq -r '.accountId' <<<"$canary_json")"
  password_secret="$(jq -r '.passwordSecret' <<<"$canary_json")"
  password_file="/run/agenix/${password_secret}"

  if [[ ! -r "$password_file" ]]; then
    echo "❌ Missing canary password secret: $password_file" >&2
    exit 1
  fi

  echo "ℹ️ Checking canary account ${account_id}..."
  kanidm_cli person get "$account_id" -H "$kanidm_url" -D idm_admin -o json >/dev/null

  reset_output="$(
    kanidm_cli person credential create-reset-token \
      "$account_id" \
      900 \
      -H "$kanidm_url" \
      -D idm_admin
  )"
  reset_url="$(
    awk '
      {
        for (field_idx = 1; field_idx <= NF; field_idx++) {
          if ($field_idx ~ /^https?:\/\//) {
            url = $field_idx
            gsub(/^[<("'\''"]+/, "", url)
            gsub(/[>"'\'',)]+$/, "", url)
            print url
            exit
          }
        }
      }
    ' <<<"$reset_output"
  )"

  if [[ -z "$reset_url" ]]; then
    echo "❌ Could not parse reset URL for ${account_id}." >&2
    echo "$reset_output" >&2
    exit 1
  fi

  tmp_json="$(mktemp "${tmpdir}/reset-token.XXXXXX.json")"
  jq \
    --arg accountId "$account_id" \
    --arg resetUrl "$reset_url" \
    --arg passwordFile "$password_file" \
    '. + [{
      accountId: $accountId,
      resetUrl: $resetUrl,
      passwordFile: $passwordFile
    }]' \
    "$reset_tokens_file" >"$tmp_json"
  mv "$tmp_json" "$reset_tokens_file"
done < <(runtime_health_snapshot_query '.accessChecks.canaries[]')

echo "ℹ️ Setting canary passwords and warming app state..."
env \
  PLAYWRIGHT_NODE_MODULE="$playwright_module" \
  RUNTIME_HEALTH_SNAPSHOT="$RUNTIME_HEALTH_SNAPSHOT" \
  RUNTIME_ACCESS_RESET_TOKENS_FILE="$reset_tokens_file" \
  nix shell nixpkgs#nodejs nixpkgs#playwright-driver nixpkgs#chromium -c \
  bash -c '
    set -euo pipefail
    export RUNTIME_ACCESS_BROWSER_EXECUTABLE="$(command -v chromium)"
    node "$1" bootstrap
  ' bash "$browser_helper_abs" >"$helper_output_file"

if jq -e '([.resetResults[]?, .warmupResults[]?] | any(.severity != "OK"))' "$helper_output_file" >/dev/null; then
  echo "❌ Access canary bootstrap reported failures; refusing to write successful bootstrap state." >&2
  jq '.' "$helper_output_file" >&2
  exit 1
fi

python3 - "$helper_output_file" "$bootstrap_state_file" <<'PY'
import json
import pathlib
import sys

helper_output = pathlib.Path(sys.argv[1])
state_path = pathlib.Path(sys.argv[2])
data = json.loads(helper_output.read_text())
state = {
    "timestamp": data.get("timestamp"),
    "resetResults": data.get("resetResults", []),
    "warmupResults": data.get("warmupResults", []),
}
state_path.write_text(json.dumps(state, indent=2) + "\n")
PY
chmod 600 "$bootstrap_state_file"

echo "✅ Wrote access canary bootstrap state to ${bootstrap_state_file}."
