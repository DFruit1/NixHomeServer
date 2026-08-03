{ pkgs }:

{ name
, backendPackage
, nativeBuildInputs ? [ ]
, extraInstallCommands ? ""
,
}:
pkgs.runCommand "${name}-runtime"
  {
    inherit nativeBuildInputs;
    meta = backendPackage.meta or { };
    passthru = (backendPackage.passthru or { }) // {
      inherit backendPackage;
    };
  }
  ''
    mkdir -p "$out"
    cp -a ${backendPackage}/. "$out/"
    chmod -R u+w "$out"
    ${extraInstallCommands}
  ''
