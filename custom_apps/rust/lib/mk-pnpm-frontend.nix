{ lib, pkgs }:

{ name
, srcDir
, pnpmDeps
, requiredOutputs
,
}:
let
  sourcePath = toString srcDir;
  mkSrc = production: lib.cleanSourceWith {
    src = srcDir;
    name = "${name}-src";
    filter = path: type:
      let
        rel = lib.removePrefix "${sourcePath}/" (toString path);
      in
      !(rel == "node_modules" || lib.hasPrefix "node_modules/" rel)
      && !(rel == "dist" || lib.hasPrefix "dist/" rel)
      && !(rel == "coverage" || lib.hasPrefix "coverage/" rel)
      && (!production || !(lib.elem (builtins.baseNameOf path) [ "tests" "__tests__" "test-support" "vitest.config.ts" ] || lib.hasInfix ".test." rel || lib.hasInfix ".spec." rel))
      && lib.cleanSourceFilter path type;
  };
  check = pkgs.stdenvNoCC.mkDerivation {
    pname = "${name}-check";
    version = "0.1.0";
    src = mkSrc false;
    inherit pnpmDeps;
    nativeBuildInputs = [ pkgs.nodejs pkgs.pnpm pkgs.pnpmConfigHook ];
    CI = "true";
    buildPhase = "pnpm run --if-present format:check && pnpm run typecheck && pnpm run test";
    installPhase = "touch $out";
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = name;
  version = "0.1.0";
  src = mkSrc true;
  inherit pnpmDeps;
  passthru = { inherit check; };

  nativeBuildInputs = [
    pkgs.nodejs
    pkgs.pnpm
    pkgs.pnpmConfigHook
  ];

  CI = "true";

  buildPhase = ''
    runHook preBuild
    pnpm run build
    for required_output in ${lib.escapeShellArgs requiredOutputs}; do
      test -f "$required_output" || {
        echo "${name} did not produce $required_output" >&2
        exit 1
      }
    done
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cp -R dist "$out"
    runHook postInstall
  '';
}
