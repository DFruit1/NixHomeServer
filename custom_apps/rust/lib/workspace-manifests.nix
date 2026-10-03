# Derives the dependency-manifest source for the shared Cargo dependency build
# from the authoritative workspace declaration instead of a pattern that sweeps
# the whole tree.
#
# The previous implementation used `craneLib.fileset.cargoTomlAndLock` over
# `custom_apps`. That pattern selects every `Cargo.toml`/`Cargo.lock` below the
# tree, including manifests belonging to unrelated projects such as the Tauri
# apps under `custom_apps/node/apps/*/src-tauri`. Editing one of those changed
# the input to `sharedCargoArtifacts` and recompiled the entire workspace
# dependency graph for nothing.
#
# Only the files Cargo reads to resolve workspace dependencies belong here: the
# root manifest, the root lockfile, workspace-level Cargo config, the
# format/toolchain config, and the manifests of every declared workspace member
# (including members reached through a glob) plus any local `path` dependency
# those manifests pull in. Manifests and lockfiles of projects outside the
# workspace are excluded by construction.

{ lib }:

{ workspaceRoot }:

let
  rootString = toString workspaceRoot;

  # Every relative path handled here is a workspace-root-relative POSIX path.
  # `lib.path.append` keeps the result a path value, which lib.fileset requires.
  resolvePath = relative: lib.path.append workspaceRoot relative;

  readManifest = relative: builtins.fromTOML (builtins.readFile (resolvePath relative));

  exists = relative: builtins.pathExists (resolvePath relative);

  optionalFile = relative: lib.fileset.maybeMissing (resolvePath relative);

  rootManifest = readManifest "Cargo.toml";
  workspaceTable = if rootManifest ? workspace then rootManifest.workspace else { };

  members = workspaceTable.members or [ ];
  excludes = workspaceTable.exclude or [ ];

  # Cargo accepts glob patterns in `members`/`exclude` ("crates/*", "apps/*-cli"),
  # so resolve them against the filesystem instead of carrying the literal text.
  patternToRegex = pattern:
    "^" + lib.concatStringsSep ".*" (map lib.escapeRegex (lib.splitString "*" pattern)) + "$";

  patternBaseDir = pattern:
    let
      static = builtins.foldl'
        (
          acc: segment: if acc.done || lib.hasInfix "*" segment then acc else {
            inherit (acc) done;
            parts = acc.parts ++ [ segment ];
          }
        )
        { done = false; parts = [ ]; }
        (lib.splitString "/" pattern);
    in
    if static.parts == [ ] then null else lib.concatStringsSep "/" static.parts;

  # Directory names under `base` (relative to the workspace root), walked to a
  # bounded depth so `crates/*/sub` resolves without descending into unrelated
  # trees.
  walkDirectories =
    base: depth:
    let
      entries =
        if base == null || !builtins.pathExists (resolvePath base) then
          { }
        else
          lib.mapAttrs (name: kind: if kind == "directory" then name else null) (builtins.readDir (resolvePath base));
      names = builtins.attrNames entries;
      child = name: if base == null then name else "${base}/${name}";
      descend = name: if depth > 0 then walkDirectories (child name) (depth - 1) else [ ];
    in
    lib.concatMap (name: if entries.${name} == null then [ ] else [ (child name) ] ++ descend name) names;

  resolvePattern = pattern:
    let
      # A literal (non-glob) member names its own directory, which sits above
      # everything `walkDirectories` yields for that base.
      literal = lib.removeSuffix "/" pattern;
      regex = patternToRegex literal;
      base = patternBaseDir literal;
      # At most one wildcard per path segment, plus one level for a nested match.
      depth = lib.length (lib.splitString "/" literal) + 1;
      candidates = walkDirectories base depth ++ [ literal ];
      matches =
        builtins.filter (candidate: lib.match regex candidate != null && exists "${candidate}/Cargo.toml") candidates;
    in
    if matches == [ ] then
      throw "workspace-manifests: workspace member pattern '${pattern}' resolved to no directory containing a Cargo.toml under ${rootString}"
    else
      matches;

  resolvePatterns = patterns: lib.unique (lib.concatMap resolvePattern patterns);

  # Cargo resolves local `path` dependencies relative to the manifest that names
  # them, so normalise them to workspace-root-relative paths.
  pathDependencies =
    manifestPath:
    let
      manifest = readManifest manifestPath;
      dir = builtins.dirOf manifestPath;
      tables = lib.filter (name: builtins.hasAttr name manifest) [
        "dependencies"
        "dev-dependencies"
        "build-dependencies"
      ];
      entries = lib.concatMap (name: builtins.attrValues manifest.${name}) tables;
      local = builtins.filter (entry: entry ? path && lib.isString entry.path) entries;
    in
    lib.unique (map (entry: if dir == "." then entry else "${dir}/${entry}") local);

  # Breadth-first closure over member manifests and their local path
  # dependencies; `visited` also terminates cycles between local crates.
  collectManifests =
    visited: pending:
    let
      next = builtins.filter (path: !(lib.elem path visited)) pending;
    in
    if next == [ ] then
      visited
    else
      collectManifests (visited ++ next) (builtins.concatMap pathDependencies next);

  declaredMembers = resolvePatterns members;
  resolvedExcludes = resolvePatterns excludes;
  activeMembers = builtins.filter (member: !(lib.elem member resolvedExcludes)) declaredMembers;

  manifestPaths = collectManifests [ ] (map (member: "${member}/Cargo.toml") activeMembers);

  # Workspace-level build configuration Cargo reads while resolving and building
  # dependencies, so a future config change is never silently ignored.
  configPaths = lib.filter exists [
    ".cargo/config.toml"
    ".cargo/config"
  ];

  stylePaths = lib.filter exists [ "rustfmt.toml" ];

  trackedPaths = manifestPaths ++ configPaths ++ stylePaths ++ [ "Cargo.toml" "Cargo.lock" ];
in

{
  source = lib.fileset.toSource {
    root = workspaceRoot;
    fileset = lib.fileset.unions (map optionalFile trackedPaths);
  };
  inherit manifestPaths activeMembers trackedPaths;
}
