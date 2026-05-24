{ craneLib }:

{ name
, src
, commonArgs
, cargoClippyExtraArgs ? "--all-targets -- --deny warnings"
, cargoNextestExtraArgs ? ""
,
}:
let
  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
in
{
  inherit cargoArtifacts;

  fmt = craneLib.cargoFmt {
    inherit src;
    pname = name;
  };

  clippy = craneLib.cargoClippy (commonArgs // {
    inherit cargoArtifacts cargoClippyExtraArgs;
  });

  test = craneLib.cargoNextest (commonArgs // {
    inherit cargoArtifacts cargoNextestExtraArgs;
    partitions = 1;
    partitionType = "count";
  });
}
