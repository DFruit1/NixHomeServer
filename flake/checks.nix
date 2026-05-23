{ self, lib, pkgs, rustApps, nodePackages }:

let
  checkNativeBuildInputs = with pkgs; [
    bash
    coreutils
    findutils
    gitMinimal
    getent
    gnugrep
    gnused
    gnutar
    jq
    nix
    ripgrep
    sqlite
    util-linux
  ];

  rustChecks = lib.concatMapAttrs
    (name: app: {
      "${name}-fmt" = app.checks.fmt;
      "${name}-clippy" = app.checks.clippy;
      "${name}-test" = app.checks.test;
    })
    rustApps;
in
{
  youtube-downloader = nodePackages.youtube-downloader;

  shellcheck = pkgs.runCommand "shellcheck"
    {
      nativeBuildInputs = with pkgs; [
        shellcheck
      ];
    } ''
    cd ${self}
    shellcheck -x -e SC1091,SC2016,SC2154,SC2029 scripts/*.sh scripts/helpers/*.sh scripts/admin/*.sh scripts/tests/*.sh bootstrap/*.sh
    touch "$out"
  '';

  deadnix = pkgs.runCommand "deadnix"
    {
      nativeBuildInputs = with pkgs; [
        deadnix
      ];
    } ''
    cd ${self}
    deadnix --fail .
    touch "$out"
  '';

  statix = pkgs.runCommand "statix"
    {
      nativeBuildInputs = with pkgs; [
        statix
      ];
    } ''
    cd ${self}
    statix check .
    touch "$out"
  '';

  repo-policy = pkgs.runCommand "repo-policy"
    {
      nativeBuildInputs = checkNativeBuildInputs;
    } ''
    export HOME="$TMPDIR"
    export NIX_CONFIG="experimental-features = nix-command flakes"
    cp -R ${self} "$TMPDIR/source"
    chmod -R u+w "$TMPDIR/source"
    cd "$TMPDIR/source"
    bash scripts/tests/run-script-tests.sh
    touch "$out"
  '';
}
  // rustChecks
