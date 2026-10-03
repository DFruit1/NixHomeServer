#!/usr/bin/env bash
# Offline DAC proof of the rollout blocker; no host privilege or server writes.
# Requires subordinate uid/gid mappings and unprivileged user namespaces.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "${1:-}" != "--inside-userns" ]]; then
  exec unshare --user --map-auto --map-root-user \
    bash "$0" --inside-userns
fi

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
chmod 0711 "$fixture"
# Copy the real helper before dropping uid, avoiding private checkout ancestry.
cp "$repo_root/scripts/helpers/deploy-archive-cleanup.sh" "$fixture/helper.sh"
chmod 0644 "$fixture/helper.sh"
mkdir "$fixture/state" "$fixture/state/archive-staging" "$fixture/control"
chmod 0700 "$fixture/state" "$fixture/state/archive-staging" "$fixture/control"
chown 1:1 "$fixture/state/archive-staging" "$fixture/control"
printf 'private stamp\n' >"$fixture/state/stamp"
chmod 0600 "$fixture/state/stamp"

# Use relative fixture paths after entering it: the host's private TMPDIR
# ancestors are intentionally not traversable by the mapped SSH-user uid.
cd "$fixture"
as_admin() { setpriv --reuid 1 --regid 1 --clear-groups "$@"; }
control="$(as_admin env NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE=control \
  bash helper.sh stage nixhomeserver-deploy)"
[[ -f "$control" ]]
echo 'ok: non-root SSH-user stand-in can stage in its own reachable 0700 directory'

if as_admin env NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE=state/archive-staging \
  bash helper.sh stage nixhomeserver-deploy; then
  echo 'FAIL: non-root caller traversed root-only parent' >&2
  exit 1
fi
if as_admin cat state/stamp; then
  echo 'FAIL: non-root caller read root-only stamp' >&2
  exit 1
fi
shopt -s nullglob dotglob
entries=("$fixture/state/archive-staging/"*)
((${#entries[@]} == 0))
# Match write_test_stamp's directory operation: installing the child alone
# cannot solve traversal, and the stamp writer keeps reasserting parent 0700.
install -d -m 0700 "$fixture/state"
[[ "$(stat -c '%a:%u' "$fixture/state")" == '700:0' ]]
echo 'ok: root:root 0700 parent blocks non-root staging and stamp access'
echo 'POLICY BLOCKER: child installation alone is insufficient; no production permissions changed'
