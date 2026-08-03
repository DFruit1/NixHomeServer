{ lib, craneLib, mkRustShell, mkRustChecks }:

{ name
, srcDir
, binaryName ? name
, modulePath
, meta ? { }
, version ? "0.1.0"
, extraSourcePrefixes ? [ ]
, packageSourceExcludePrefixes ? [ "tests" ]
, extraDevShellPackages ? [ ]
, shellEnv ? { }
, shellHook ? ""
, cargoExtraArgs ? "--locked"
, nativeBuildInputs ? [ ]
, buildInputs ? [ ]
,
}:
let
  sourcePath = srcDir;
  sourcePathString = toString sourcePath;

  pathRelativeToSource =
    path:
    let
      pathString = toString path;
    in
    if pathString == sourcePathString then
      ""
    else
      lib.removePrefix "${sourcePathString}/" pathString;

  pathMatchesPrefix = rel: prefix:
    rel == prefix
    || lib.hasPrefix "${prefix}/" rel;

  pathIsPrefixParent = rel: prefix:
    rel != "" && lib.hasPrefix "${rel}/" prefix;

  keepExtraPath = rel:
    rel == ""
    || lib.any
      (
        prefix:
        pathMatchesPrefix rel prefix || pathIsPrefixParent rel prefix
      )
      extraSourcePrefixes;

  mkSource = sourceName: excludedPrefixes:
    lib.cleanSourceWith {
      src = sourcePath;
      name = sourceName;
      filter =
        path: type:
        let
          rel = pathRelativeToSource path;
          excluded = lib.any (pathMatchesPrefix rel) excludedPrefixes;
        in
        lib.cleanSourceFilter path type
        && !excluded
        && (
          craneLib.filterCargoSources path type
          || keepExtraPath rel
        );
    };

  packageSrc = mkSource "${name}-package-src" packageSourceExcludePrefixes;
  checkSrc = mkSource "${name}-check-src" [ ];

  commonArgs = {
    inherit version cargoExtraArgs nativeBuildInputs buildInputs;
    pname = name;
    strictDeps = true;
  };

  rawChecks = mkRustChecks {
    inherit name packageSrc checkSrc commonArgs;
  };

  package = craneLib.buildPackage (commonArgs // {
    inherit (rawChecks) cargoArtifacts;
    src = packageSrc;
    doCheck = false;
    meta = meta // {
      mainProgram = binaryName;
    };
  });

  checks = builtins.removeAttrs rawChecks [ "cargoArtifacts" ];
  devShell = mkRustShell {
    name = name;
    inherit checks shellHook;
    extraPackages = extraDevShellPackages;
    extraEnv = shellEnv;
  };
in
{
  inherit package devShell checks binaryName modulePath meta;
  backendPackage = package;
}
