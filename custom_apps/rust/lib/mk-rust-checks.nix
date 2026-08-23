{ lib, craneLib }:

{ name
, packageSrc
, checkSrc
, commonArgs
, cargoArtifacts ? null
, cargoLock ? null
, cargoClippyExtraArgs ? "--all-targets -- --deny warnings"
, cargoNextestExtraArgs ? ""
,
}:
let
  # When part of a shared Cargo workspace, the dependency artifacts are built
  # once at the workspace level and reused here instead of being rebuilt per
  # crate.
  cargoArtifactsFinal = if cargoArtifacts != null
    then cargoArtifacts
    else craneLib.buildDepsOnly (commonArgs // {
      src = packageSrc;
    });
in
{
  inherit cargoArtifactsFinal;

  fmt = craneLib.cargoFmt {
    src = checkSrc;
    pname = name;
  };

  clippy = craneLib.cargoClippy (commonArgs // {
    inherit cargoClippyExtraArgs;
    cargoArtifacts = cargoArtifactsFinal;
    src = checkSrc;
  } // lib.optionalAttrs (cargoLock != null) { inherit cargoLock; });

  test = craneLib.cargoNextest (commonArgs // {
    inherit cargoNextestExtraArgs;
    cargoArtifacts = cargoArtifactsFinal;
    src = checkSrc;
    partitions = 1;
    partitionType = "count";
  } // lib.optionalAttrs (cargoLock != null) { inherit cargoLock; });
}
