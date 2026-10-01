{ lib, craneLib }:

{ name
, packageSrc
, checkSrc
, commonArgs
, cargoArtifacts ? null
, cargoLock ? null
, cargoFmtExtraArgs ? ""
, cargoClippyExtraArgs ? "--all-targets -- --deny warnings"
, cargoNextestExtraArgs ? ""
,
}:
let
  # When part of a shared Cargo workspace, the dependency artifacts are built
  # once at the workspace level and reused here instead of being rebuilt per
  # crate.
  cargoArtifactsFinal =
    if cargoArtifacts != null
    then cargoArtifacts
    else
      craneLib.buildDepsOnly (commonArgs // {
        src = packageSrc;
      });

  # clippy/nextest only link the shared dependency artifacts plus the crate
  # under test, so release LTO and single-unit codegen buy nothing here: drop
  # both (cargo profile env config overrides the workspace profile) to keep
  # the check derivations cheap.
  checkProfileEnv = {
    CARGO_PROFILE_RELEASE_LTO = "false";
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16";
  };
in
{
  inherit cargoArtifactsFinal;

  fmt = craneLib.cargoFmt {
    src = checkSrc;
    pname = name;
    inherit (commonArgs) version;
    cargoExtraArgs = cargoFmtExtraArgs;
  };

  clippy = craneLib.cargoClippy (commonArgs // checkProfileEnv // {
    inherit cargoClippyExtraArgs;
    cargoArtifacts = cargoArtifactsFinal;
    src = checkSrc;
  } // lib.optionalAttrs (cargoLock != null) { inherit cargoLock; });

  test = craneLib.cargoNextest (commonArgs // checkProfileEnv // {
    inherit cargoNextestExtraArgs;
    cargoArtifacts = cargoArtifactsFinal;
    src = checkSrc;
    partitions = 1;
    partitionType = "count";
  } // lib.optionalAttrs (cargoLock != null) { inherit cargoLock; });
}
