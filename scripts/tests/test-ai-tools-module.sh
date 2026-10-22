#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
ensure_tools jq nix
host="$(test_default_host)"
if [[ "$(flake_eval_json "in builtins.elem \"ai-tools\" (builtins.getAttr \"$host\" f.lib.nixhomeserverSettings).enabledApps")" != true ]]; then
  echo 'AI Tools is disabled; skipping its enabled-module contract.'
  exit 0
fi

# The published host name is the regression this test exists for: rmcp rejects
# any Host it was not configured with, Caddy forwards the client's Host
# unchanged, and the only symptom is a 403 on every request through the gateway.
# Asserting the unit exports it is far cheaper than finding that on the
# deployed endpoint.
value="$(flake_eval_json "
  cfg = (builtins.getAttr \"$host\" f.nixosConfigurations).config;
  vars = builtins.getAttr \"$host\" f.lib.nixhomeserverSettings;
  svc = cfg.systemd.services.ai-tools;
  shared = cfg.systemd.services.ai-tools-shared-access;
  app = cfg.repo.aiTools;
  gateway = cfg.repo.authGateway.protectedApps.aiTools;
  guarded = cfg.repo.storage.dataPool.guardedServices;
in {
  publicHost = \"tools.\${vars.domain}\";
  envPublicHost = svc.environment.AI_TOOLS_PUBLIC_HOST;
  envListen = svc.environment.AI_TOOLS_LISTEN;
  envSharedRoot = svc.environment.AI_TOOLS_SHARED_ROOT;
  envSearxng = svc.environment.AI_TOOLS_SEARXNG_URL;
  gatewayHost = gateway.host;
  gatewayUpstream = gateway.upstream;
  ipDeny = svc.serviceConfig.IPAddressDeny;
  ipAllow = svc.serviceConfig.IPAddressAllow;
  onFailure = svc.unitConfig.OnFailure;
  alertTarget = cfg.repo.monitoring.failureAlerts.targetUnit;
  requiresMounts = svc.serviceConfig.RequiresMountsFor;
  readOnlyPaths = svc.serviceConfig.ReadOnlyPaths;
  user = svc.serviceConfig.User;
  aclScript = shared.script;
  aclBefore = shared.before;
  guardedService = builtins.elem \"ai-tools\" guarded;
  guardedAcl = builtins.elem \"ai-tools-shared-access\" guarded;
  listen = app.listenAddress;
  port = app.port;
  gatewayMode = cfg.repo.authGateway.mode;
  disableEvaluation = (f.nixosConfigurations.\"$host\".extendModules { modules = [
    ({ lib, ... }: { repo.aiTools.enable = lib.mkForce false; })
  ]; }).config.systemd.services.ai-tools.wantedBy or [];
}")"

jq -e '
  .alertTarget as $alert
  | .envSharedRoot as $shared
  | (
  .envPublicHost == .publicHost
  and .gatewayHost == .publicHost
  and (.envListen | startswith("127.0.0.1:"))
  and (.envSearxng | startswith("http://127.0.0.1:"))
  and (.gatewayUpstream | startswith("http://127.0.0.1:"))
  and (.envSharedRoot | startswith("/"))
  and .ipDeny == "any"
  and .ipAllow == "localhost"
  and (.onFailure | index($alert) != null)
  and (.requiresMounts | index($shared) != null)
  and (.readOnlyPaths | index($shared) != null)
  and .user == "ai-tools"
  and (.aclScript | contains("g:ai-tools:r-x"))
  and (.aclScript | contains("setfacl -P -R -m \"g:ai-tools:r-X\""))
  and (.aclScript | contains("-type d -exec setfacl -m \"d:g:ai-tools:r-x\""))
  and (.aclBefore | index("ai-tools.service") != null)
  and .guardedService
  and .guardedAcl
  and .listen == "127.0.0.1"
  and .port == 8097
  and .gatewayMode == "gateway"
  and (.disableEvaluation | length == 0)
  )
' <<<"$value" >/dev/null ||
  {
    echo "❌ AI Tools public host, egress confinement or shared-root access regressed." >&2
    jq . <<<"$value" >&2
    exit 1
  }

# The declaration assertions above only read the script as text. This runs the
# production script itself against a real tree and then reads the result as the
# service account would, so a root-only grant cannot pass again.
acl_script="$(jq -er '.aclScript' <<<"$value")"

# The fixture executes the real script, so it gets a runtime closure of its own
# rather than the test host's PATH. It is the unit's declared `path` plus
# util-linux, so a tool the script needs but `path` omits is caught rather than
# silently borrowed from the machine running the suite.
fixture_runtime="$(nix build --impure --no-link --print-out-paths --expr "
  let
    f = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
    pkgs = import f.inputs.nixpkgs { system = \"x86_64-linux\"; };
  in pkgs.buildEnv {
    name = \"ai-tools-acl-fixture-runtime\";
    paths = with pkgs; [ acl coreutils findutils gnugrep util-linux ];
  }
")"
export PATH="$fixture_runtime/bin:$PATH"
for tool in setfacl getfacl find setpriv unshare mount install; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "❌ The AI Tools ACL fixture cannot run: $tool is unavailable." >&2
    exit 1
  fi
done

# Deliberately under /tmp rather than TMPDIR: the fixture reads the tree back as
# an unrelated uid, so every ancestor directory must be traversable. A private
# TMPDIR (the agent scratch directory is 0700) would deny access to the fixture
# itself and make the access assertions meaningless rather than failing usefully.
fixture_dir="$(mktemp -d /tmp/ai-tools-acl.XXXXXX)"
cleanup() { rm -rf "$fixture_dir"; }
trap cleanup EXIT
chmod 0755 "$fixture_dir"

# The service account is a stand-in: an unmapped uid in the ai-tools gid, which
# the group database below binds to the real group name the script grants by.
# uid 1 is the mapped nobody, so nothing here is the caller's own identity.
printf 'root:x:0:\nai-tools:x:4242:\n' >"$fixture_dir/group"

# Only the shared root is substituted; the rest is the evaluated unit script.
while IFS= read -r line; do
  if [[ "$line" == root=* ]]; then
    printf "root='%s'\n" "$fixture_dir/shared"
  else
    printf '%s\n' "$line"
  fi
done <<<"$acl_script" >"$fixture_dir/acl.sh"

mkdir -p "$fixture_dir/shared/docs/nested" "$fixture_dir/outside" "$fixture_dir/staging"
printf 'topsecret\n' >"$fixture_dir/outside/other.txt"
printf 'nested document\n' >"$fixture_dir/shared/docs/nested/doc.txt"
printf 'top level document\n' >"$fixture_dir/shared/top.txt"
# Pre-existing, private, and nested: exactly what a root-only grant misses.
chmod 0770 "$fixture_dir/shared/docs" "$fixture_dir/shared/docs/nested"
chmod 0660 "$fixture_dir/shared/docs/nested/doc.txt"
chmod 0600 "$fixture_dir/outside/other.txt"
ln -s "$fixture_dir/outside/other.txt" "$fixture_dir/shared/escape.txt"

# Runs inside the namespaces: the mount namespace binds the fixture group
# database over /etc/group so the script resolves the group name, and the user
# namespace supplies the uid mapping setpriv needs to drop to the service gid.
read -r -d '' acl_fixture_body <<'FIXTURE' || true
set -euo pipefail
fixture_dir="$1"
mount --bind "$fixture_dir/group" /etc/group
as_service() { setpriv --reuid 1 --regid 4242 --clear-groups "$@"; }
root="$fixture_dir/shared"

unreadable() {
  if as_service cat "$1" >/dev/null 2>&1; then
    echo "❌ AI Tools could read $1 before the grant was applied." >&2
    exit 1
  fi
}
unreadable "$root/docs/nested/doc.txt"

bash "$fixture_dir/acl.sh"

# Pre-existing and nested content, read as the service account.
as_service cat "$root/docs/nested/doc.txt" >/dev/null
as_service cat "$root/top.txt" >/dev/null

# Read-only: the grant must not let the service modify what it converts.
if as_service sh -c "printf tamper >> '$root/docs/nested/doc.txt'" 2>/dev/null; then
  echo "❌ AI Tools could write a shared document." >&2
  exit 1
fi

# A link out of the shared root must not become readable through the grant.
unreadable "$root/escape.txt"

# Freshly created content inherits the directory default without a re-run.
(umask 077; mkdir "$root/fresh"; printf 'fresh\n' >"$root/fresh/new.txt")
as_service cat "$root/fresh/new.txt" >/dev/null

# Content moved in from elsewhere does not inherit anything, so it needs the
# next activation to repair it, and is readable after that.
install -d -m 0770 "$fixture_dir/staging/drop"
printf 'moved in\n' >"$fixture_dir/staging/drop/moved.txt"
chmod 0660 "$fixture_dir/staging/drop/moved.txt"
mv "$fixture_dir/staging/drop" "$root/drop"
unreadable "$root/drop/moved.txt"
bash "$fixture_dir/acl.sh"
as_service cat "$root/drop/moved.txt" >/dev/null
FIXTURE

printf '%s' "$acl_fixture_body" >"$fixture_dir/fixture.sh"

if [[ "$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0)" == 0 ]]; then
  echo "ℹ️ Unprivileged user namespaces are unavailable; skipping the AI Tools ACL access fixture."
  echo "AI Tools public host, egress confinement, shared-root ACL and data-pool guard passed."
  exit 0
fi

if ! unshare --user --map-auto --map-root-user --mount \
  bash "$fixture_dir/fixture.sh" "$fixture_dir"; then
  echo "❌ The AI Tools shared-root grant does not give the service account read access to existing, nested and moved-in documents." >&2
  exit 1
fi

echo "AI Tools public host, egress confinement, shared-root ACL and data-pool guard passed."