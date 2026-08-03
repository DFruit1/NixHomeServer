{ craneLib }:

{ name
, packageSrc
, checkSrc
, commonArgs
, cargoClippyExtraArgs ? "--all-targets -- --deny warnings"
, cargoNextestExtraArgs ? ""
,
}:
let
  cargoArtifacts = craneLib.buildDepsOnly (commonArgs // {
    src = packageSrc;
  });
in
{
  inherit cargoArtifacts;

  fmt = craneLib.cargoFmt {
    src = checkSrc;
    pname = name;
  };

  clippy = craneLib.cargoClippy (commonArgs // {
    inherit cargoArtifacts cargoClippyExtraArgs;
    src = checkSrc;
  });

  test = craneLib.cargoNextest (commonArgs // {
    inherit cargoArtifacts cargoNextestExtraArgs;
    src = checkSrc;
    partitions = 1;
    partitionType = "count";
  });
}
