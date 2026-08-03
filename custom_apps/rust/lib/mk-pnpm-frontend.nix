{ lib, pkgs }:

{ name
, srcDir
, pnpmDeps
, requiredOutputs
,
}:
let
  sourcePath = toString srcDir;
  src = lib.cleanSourceWith {
    src = srcDir;
    name = "${name}-src";
    filter = path: type:
      let
        rel = lib.removePrefix "${sourcePath}/" (toString path);
      in
      !(rel == "node_modules" || lib.hasPrefix "node_modules/" rel)
      && !(rel == "dist" || lib.hasPrefix "dist/" rel)
      && !(rel == "coverage" || lib.hasPrefix "coverage/" rel)
      && lib.cleanSourceFilter path type;
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = name;
  version = "0.1.0";
  inherit src pnpmDeps;

  nativeBuildInputs = [
    pkgs.nodejs
    pkgs.pnpm
    pkgs.pnpmConfigHook
  ];

  CI = "true";

  buildPhase = ''
    runHook preBuild
    pnpm run check
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
