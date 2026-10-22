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
  workspaceDirs = lib.filter
    (name: name == app.workspaceDirName)
    cfg.repo.storage.sharedRoots.contentSubdirs;
  workspaceProvisions = lib.filter
    (dir: dir.path == app.workspaceRoot)
    cfg.repo.storage.dataPool.directories;
in {
  publicHost = \"tools.\${vars.domain}\";
  envPublicHost = svc.environment.AI_TOOLS_PUBLIC_HOST;
  envListen = svc.environment.AI_TOOLS_LISTEN;
  envSharedRoot = svc.environment.AI_TOOLS_SHARED_ROOT;
  envWorkspace = svc.environment.AI_TOOLS_WORKSPACE_ROOT;
  envSearxng = svc.environment.AI_TOOLS_SEARXNG_URL;
  gatewayHost = gateway.host;
  gatewayUpstream = gateway.upstream;
  ipDeny = svc.serviceConfig.IPAddressDeny;
  ipAllow = svc.serviceConfig.IPAddressAllow;
  onFailure = svc.unitConfig.OnFailure;
  alertTarget = cfg.repo.monitoring.failureAlerts.targetUnit;
  requiresMounts = svc.serviceConfig.RequiresMountsFor;
  readOnlyPaths = svc.serviceConfig.ReadOnlyPaths;
  readWritePaths = svc.serviceConfig.ReadWritePaths;
  memoryHigh = svc.serviceConfig.MemoryHigh;
  memoryMax = svc.serviceConfig.MemoryMax;
  user = svc.serviceConfig.User;
  aclScript = shared.script;
  aclBefore = shared.before;
  guardedService = builtins.elem \"ai-tools\" guarded;
  guardedAcl = builtins.elem \"ai-tools-shared-access\" guarded;
  listen = app.listenAddress;
  port = app.port;
  workspaceRoot = app.workspaceRoot;
  workspaceDirs = workspaceDirs;
  workspaceProvisions = workspaceProvisions;
  # The confinement this card exists for: reads keep the whole shared root,
  # writes are confined to the workspace, and the workspace is a child of it.
  workspaceUnderSharedRoot =
    app.workspaceRoot != app.sharedRoot
    && lib.hasPrefix \"\${app.sharedRoot}/\" app.workspaceRoot;
  # Nothing but the workspace may be writable, and it must not sit outside the
  # read-only root where the mount would not nest.
  writePathsExactlyWorkspace =
    svc.serviceConfig.ReadWritePaths == [ app.workspaceRoot ];
  readOnlyIsWholeSharedRoot =
    svc.serviceConfig.ReadOnlyPaths == [ app.sharedRoot ];
  # The workspace is deliberately unbacked-up; a snapshot root reaching it is
  # the regression to catch.
  snapshotRoots = cfg.repo.backups.snapshotRoots;
  snapshotRootsCoverWorkspace = lib.any
    (root: app.workspaceRoot == root || lib.hasPrefix \"\${root}/\" app.workspaceRoot)
    cfg.repo.backups.snapshotRoots;
  gatewayMode = cfg.repo.authGateway.mode;
  disableEvaluation = (f.nixosConfigurations.\"$host\".extendModules { modules = [
    ({ lib, ... }: { repo.aiTools.enable = lib.mkForce false; })
  ]; }).config.systemd.services.ai-tools.wantedBy or [];
}")"

jq -e '
  .alertTarget as $alert
  | .envSharedRoot as $shared
  | .envWorkspace as $workspace
  | (
  .envPublicHost == .publicHost
  and .gatewayHost == .publicHost
  and (.envListen | startswith("127.0.0.1:"))
  and (.envSearxng | startswith("http://127.0.0.1:"))
  and (.gatewayUpstream | startswith("http://127.0.0.1:"))
  and (.envSharedRoot | startswith("/"))
  and (.envWorkspace | startswith($shared + "/"))
  and .ipDeny == "any"
  and .ipAllow == "localhost"
  and (.onFailure | index($alert) != null)
  and (.requiresMounts | index($shared) != null)
  and (.requiresMounts | index($workspace) != null)
  and (.readOnlyPaths | index($shared) != null)
  and (.readWritePaths | index($workspace) != null)
  and .readOnlyIsWholeSharedRoot
  and .writePathsExactlyWorkspace
  and .workspaceUnderSharedRoot
  and (.workspaceRoot == $workspace)
  and (.workspaceDirs | index("ai-workspace") != null)
  and (.workspaceProvisions | length == 1)
  and (.workspaceProvisions[0].mode == "0770")
  and (.workspaceProvisions[0].path == $workspace)
  and (.memoryHigh != null)
  and (.memoryMax != null)
  and .user == "ai-tools"
  and (.aclScript | contains("g:ai-tools:r-x"))
  and (.aclScript | contains("g:ai-tools:rwx"))
  and (.aclScript | contains("$workspace"))
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

# The inference unit must gain nothing from the workspace: the grant belongs to
# ai-tools alone, so the account llama-server runs as cannot write it either.
inference="$(flake_eval_json "
  cfg = (builtins.getAttr \"$host\" f.nixosConfigurations).config;
  app = cfg.repo.aiTools;
  qwen = cfg.systemd.services.qwen-27b-llama;
in {
  workspace = app.workspaceRoot;
  qwenUser = qwen.serviceConfig.User or \"__absent__\";
  qwenReadOnlyPaths = qwen.serviceConfig.ReadOnlyPaths or [ \"__absent__\" ];
  qwenReadWritePaths = qwen.serviceConfig.ReadWritePaths or [ \"__absent__\" ];
  qwenSupplementaryGroups =
    qwen.serviceConfig.SupplementaryGroups or [ \"__absent__\" ];
}")"

jq -e '
  . as $inference
  | (
  ($inference.qwenUser != "ai-tools")
  and ($inference.qwenReadWritePaths | index($inference.workspace) == null)
  and ($inference.qwenReadOnlyPaths | index($inference.workspace) == null)
  and ($inference.qwenSupplementaryGroups | index("ai-tools") == null)
  )
' <<<"$inference" >/dev/null ||
  {
    echo "❌ The inference unit gained access to the AI workspace." >&2
    jq . <<<"$inference" >&2
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

# The fixture is one behavioural block so both modes execute the same code. In
# strict mode the runtime closure lives in the server's store, so the block runs
# there instead of realising or copying that output onto this workstation.
ai_tools_acl_behaviour() {
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

# Only the shared root and the workspace are substituted; the rest is the
# evaluated unit script. Without the workspace substitution the fixture would
# try to provision the real data-pool path.
while IFS= read -r line; do
  if [[ "$line" == root=* ]]; then
    printf "root='%s'\n" "$fixture_dir/shared"
  elif [[ "$line" == workspace=* ]]; then
    printf "workspace='%s'\n" "$fixture_dir/workspace"
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

# The workspace is the one writable place, and its write entry has to survive
# the recursive read grant applied to the root above it.
as_service sh -c "printf 'scratch\n' > '$fixture_dir/workspace/scratch.txt'"

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

echo "AI Tools public host, egress confinement, shared-root ACL, workspace-only writes and data-pool guard passed."
}

if strict_remote_enabled; then
  remote_run 'set -euo pipefail
tree="$1"; shift
fixture_runtime="$1"; shift
acl_script="$1"; shift
cd "$tree"
eval "$1"
ai_tools_acl_behaviour' "$fixture_runtime" "$acl_script" "$(declare -f ai_tools_acl_behaviour)"
else
  ai_tools_acl_behaviour
fi
