{ lib, pkgs }:

{ name
, srcDir
, hash
, version ? "0.1.0"
,
}:
let
  sourcePath = toString srcDir;
  dependencySource = lib.cleanSourceWith {
    src = srcDir;
    name = "${name}-dependency-src";
    filter = path: _type:
      let
        relative = lib.removePrefix "${sourcePath}/" (toString path);
      in
      relative == "" || builtins.elem relative [ "package.json" "pnpm-lock.yaml" ];
  };
in
pkgs.fetchPnpmDeps {
  pname = name;
  inherit version;
  src = dependencySource;
  fetcherVersion = 3;
  inherit hash;
}
