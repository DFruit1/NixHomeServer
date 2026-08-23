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
, # Optional workspace mode: build against a shared source tree and prebuilt
  # dependency artifacts so common crates (tokio/axum/serde/…) compile once.
  workspaceSrc ? null
, sharedCargoArtifacts ? null
, cargoLock ? null
,
}:
let
  useWorkspace = workspaceSrc != null;

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

  packageSrc = if useWorkspace then workspaceSrc else mkSource "${name}-package-src" packageSourceExcludePrefixes;
  checkSrc = if useWorkspace then workspaceSrc else mkSource "${name}-check-src" [ ];

  # In workspace mode, scope every cargo invocation to this package and reuse
  # the shared dependency artifacts. clippy/nextest inherit cargoExtraArgs, so
  # --package is added only here (not in the clippy/nextest extra-args).
  workspaceCargoExtraArgs = lib.optionalString useWorkspace "--package ${name}";
  effectiveCargoExtraArgs = lib.trim "${cargoExtraArgs} ${workspaceCargoExtraArgs}";

  commonArgs = {
    inherit version nativeBuildInputs buildInputs;
    pname = name;
    strictDeps = true;
    cargoExtraArgs = effectiveCargoExtraArgs;
  };

  cargoArtifacts = if sharedCargoArtifacts != null
    then sharedCargoArtifacts
    else craneLib.buildDepsOnly (commonArgs // {
      src = packageSrc;
    });

  rawChecks = mkRustChecks {
    inherit name packageSrc checkSrc commonArgs cargoLock;
    cargoArtifacts = if sharedCargoArtifacts != null then sharedCargoArtifacts else null;
  };

  package = craneLib.buildPackage (commonArgs // {
    inherit cargoArtifacts;
    src = packageSrc;
    doCheck = false;
    meta = meta // {
      mainProgram = binaryName;
    };
  } // lib.optionalAttrs (cargoLock != null) { inherit cargoLock; });

  checks = builtins.removeAttrs rawChecks [ "cargoArtifactsFinal" ];
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
