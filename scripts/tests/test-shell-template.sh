#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
ensure_tools nix jq

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export SHELL_TEMPLATE_FIXTURE="$test_root/script.sh.in"
cat >"$SHELL_TEMPLATE_FIXTURE" <<'EOF'
printf '%s' @NIX_VALUE@
EOF
result="$(flake_eval_json '
  render = import ./lib/render-shell-template.nix { inherit lib; };
  path = /. + builtins.getEnv "SHELL_TEMPLATE_FIXTURE";
  value = "a quote '\'' and $(exit 99) and @NIX_VALUE@";
in {
  inherit value;
  script = render path { VALUE = lib.escapeShellArg value; };
  missingRejected = !(builtins.tryEval (builtins.stringLength (render path { }))).success;
}')"
jq -e '.missingRejected' <<<"$result" >/dev/null
jq -r '.script' <<<"$result" >"$test_root/script.sh"
actual="$(bash "$test_root/script.sh")"
[[ "$actual" == "$(jq -r '.value' <<<"$result")" ]]
echo '✅ Shell template rendering preserves quoted values and rejects missing parameters.'
