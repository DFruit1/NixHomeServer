{ lib, pkgs, craneLib }:

{ name, workspaceRoot, workspaceManifests, cargoLock, dependencyPaths ? [ "rust/lib-rs" ], memberPath ? "rust/apps/${name}", excludePrefixes ? [ "tests" ], extraSourcePrefixes ? [ ] }:

let
  memberPaths = [ memberPath ] ++ dependencyPaths;
  ownedSource = lib.cleanSourceWith {
    src = workspaceRoot;
    name = "${name}-owned-source";
    filter = path: type:
      let
        relative = lib.removePrefix "${toString workspaceRoot}/" (toString path);
        generated = lib.elem (builtins.baseNameOf path) [ "target" "node_modules" "dist" "coverage" ];
        member = lib.any (prefix: relative == prefix || lib.hasPrefix "${prefix}/" relative) memberPaths;
        appRelative = lib.removePrefix "${memberPath}/" relative;
        excluded = lib.any (prefix: appRelative == prefix || lib.hasPrefix "${prefix}/" appRelative) excludePrefixes;
        extra = lib.elem appRelative extraSourcePrefixes;
        ancestor = lib.any (prefix: lib.hasPrefix "${relative}/" prefix) memberPaths;
      in
      !generated && !excluded && lib.cleanSourceFilter path type
      && ((type == "directory" && ancestor)
      || (member && (craneLib.filterCargoSources path type || extra)));
  };
  # Cargo still needs valid targets for every workspace member when resolving
  # the shared lockfile. Only manifest-derived stubs represent sibling apps.
  dummySource = craneLib.mkDummySrc { src = workspaceManifests; inherit cargoLock; };
in
pkgs.runCommand "${name}-workspace-source" { } ''
  mkdir -p "$out"
  cp -R --no-preserve=mode ${dummySource}/. "$out/"
  cp -R --no-preserve=mode ${workspaceManifests}/. "$out/"
  ${lib.concatMapStringsSep "\n" (member: ''
    rm -rf "$out/${member}"
    mkdir -p "$out/$(dirname ${lib.escapeShellArg member})"
    cp -R --no-preserve=mode ${ownedSource}/${member} "$out/${member}"
  '') memberPaths}
''
