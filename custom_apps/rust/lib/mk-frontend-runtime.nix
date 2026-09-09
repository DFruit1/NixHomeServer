{ lib, pkgs }:

# Wraps a `mkRustApp` result so the built Qwik frontend is assembled into the
# runtime package alongside the backend binary, and exposed as a build check.
# `copies` is a list of { from, to } paths inside the frontend output; each is
# copied to share/<name>/<to> in the runtime package.
{ name
, app
, frontendDist
, copies
,
}:
app // {
  backendPackage = app.package;
  package = (import ./assemble-runtime-package.nix { inherit pkgs; }) {
    name = name;
    backendPackage = app.package;
    extraInstallCommands = lib.concatMapStrings
      ({ from, to }: ''
        mkdir -p "$out/share/${name}"
        cp -R --no-preserve=mode ${frontendDist}/${from} "$out/share/${name}/${to}"
      '')
      copies;
  };
  checks = app.checks // {
    inherit frontendDist;
  };
}
