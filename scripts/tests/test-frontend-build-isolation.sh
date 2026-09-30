#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
ensure_tools nix jq

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export FRONTEND_ISOLATION_FIXTURE="$test_root"
for variant in baseline tests support config implementation html; do
  root="$test_root/$variant"
  mkdir -p "$root/src/test-support" "$root/tests"
  printf '{"name":"fixture","scripts":{"build":"vite build","check":"vitest run && vite build"}}\n' >"$root/package.json"
  printf 'lockfileVersion: 9.0\n' >"$root/pnpm-lock.yaml"
  printf 'export const value = 1;\n' >"$root/src/app.ts"
  printf 'expect(value).toBe(1);\n' >"$root/src/app.test.ts"
  printf 'expect(value).toBe(1);\n' >"$root/tests/app.spec.ts"
  printf 'export const fixture = 1;\n' >"$root/src/test-support/fixture.ts"
  printf 'export default {};\n' >"$root/vitest.config.ts"
  printf '<html>App entry</html>\n' >"$root/index.html"
done
printf '// test edit\n' >>"$test_root/tests/src/app.test.ts"
printf '// fixture edit\n' >>"$test_root/support/src/test-support/fixture.ts"
printf '// config edit\n' >>"$test_root/config/vitest.config.ts"
printf '// implementation edit\n' >>"$test_root/implementation/src/app.ts"
printf '<!-- entry edit -->\n' >>"$test_root/html/index.html"

result="$(flake_eval_json '
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  mkFrontend = import ./custom_apps/rust/lib/mk-pnpm-frontend.nix { inherit lib pkgs; };
  source = variant:
    let package = mkFrontend {
      name = "fixture";
      srcDir = /. + (builtins.getEnv "FRONTEND_ISOLATION_FIXTURE" + "/" + variant);
      pnpmDeps = pkgs.runCommand "fixture-pnpm-deps" {} "mkdir -p $out";
      requiredOutputs = [ "dist/index.html" ];
    };
    in {
      production = package.drvPath;
      validation = package.check.drvPath;
    };
in lib.genAttrs [ "baseline" "tests" "support" "config" "implementation" "html" ] source
')"
jq -e '
  .baseline.production == .tests.production and
  .baseline.production == .config.production and
  .baseline.production == .support.production and
  .baseline.production != .implementation.production and
  .baseline.production != .html.production and
  .baseline.validation != .tests.validation and
  .baseline.validation != .config.validation and
  .baseline.validation != .support.validation and
  .baseline.validation != .implementation.validation and
  .baseline.validation != .html.validation
' <<<"$result" >/dev/null
echo '✅ Frontend test/config edits invalidate validation without rebuilding shipped assets.'
