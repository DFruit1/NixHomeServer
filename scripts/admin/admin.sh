#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/admin/admin.sh doctor [--host <site-or-hostname>]
  scripts/admin/admin.sh init-site [--site <name>]
  scripts/admin/admin.sh storage-plan [--host <site-or-hostname>]
  scripts/admin/admin.sh status [--host <site-or-hostname>] [--target <user@host>] [--refresh]
  scripts/admin/admin.sh explain [--host <site-or-hostname>]
  scripts/admin/admin.sh render-runbook --host <site-or-hostname>
  scripts/admin/admin.sh secrets check
  scripts/admin/admin.sh deploy test|switch [deploy-with-validation args...]
  scripts/admin/admin.sh fast-rebuild [rebuild-remote-fast args...]
  scripts/admin/admin.sh users [kanidm-admin args...]
  scripts/admin/admin.sh welcome [--host <site-or-hostname>]
EOF
}

subcommand="${1:-}"
if [[ -z "$subcommand" ]]; then
  usage >&2
  exit 1
fi
shift

case "$subcommand" in
  doctor)
    exec "$admin_script_dir/doctor.sh" "$@"
    ;;
  init-site)
    exec "$admin_script_dir/init-site.sh" "$@"
    ;;
  storage-plan)
    exec "$admin_script_dir/storage-plan.sh" "$@"
    ;;
  status)
    exec "$admin_script_dir/status.sh" "$@"
    ;;
  explain)
    exec "$admin_script_dir/explain.sh" "$@"
    ;;
  render-runbook)
    exec "$admin_script_dir/render-runbook.sh" "$@"
    ;;
  secrets)
    case "${1:-}" in
      check)
        shift
        exec "$admin_script_dir/doctor.sh" "$@"
        ;;
      *)
        usage >&2
        exit 1
        ;;
    esac
    ;;
  deploy)
    action="${1:-test}"
    shift || true
    exec ./scripts/deploy-with-validation.sh --action "$action" "$@"
    ;;
  fast-rebuild)
    exec ./scripts/rebuild-remote-fast.sh "$@"
    ;;
  users)
    exec nix run .#kanidm-admin -- "$@"
    ;;
  welcome)
    host="$(host_arg_or_default "$@")"
    echo "NixHomeServer admin welcome"
    echo
    "$admin_script_dir/render-runbook.sh" --host "$host" | sed -n '1,80p'
    echo
    echo "Health commands:"
    echo "  nix run .#doctor -- --host ${host}"
    echo "  sudo ./scripts/check-runtime-readiness.sh --profile manual"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
