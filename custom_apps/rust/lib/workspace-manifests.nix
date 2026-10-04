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
# those manifests and the root `[workspace.dependencies]` table pull in.
# Manifests and lockfiles of projects outside the workspace are excluded by
# construction.

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
  workspaceTable = rootManifest.workspace or { };

  members = workspaceTable.members or [ ];
  excludes = workspaceTable.exclude or [ ];

  # Cargo accepts glob patterns in `members`/`exclude` ("crates/*", "apps/*-cli"),
  # so resolve them against the filesystem instead of carrying the literal text.
  patternToRegex = pattern:
    "^" + lib.concatStringsSep ".*" (map lib.escapeRegex (lib.splitString "*" pattern)) + "$";

  # The leading literal prefix of a pattern, i.e. everything before the first
  # segment containing a wildcard. `crates/*/sub` yields `crates`: the prefix
  # stops at the first wildcard instead of skipping it and continuing, which
  # would produce the nonexistent base `crates/sub`.
  patternBaseDir = pattern:
    let
      static = builtins.foldl'
        (
          acc: segment:
            if acc.done || lib.hasInfix "*" segment then {
              done = true;
              inherit (acc) parts;
            } else {
              done = false;
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

  # Cargo's glob matches exactly the pattern, so `crates/*` must not also pick up
  # `crates/one/sub`. `walkDirectories` returns `base` itself plus `depth`
  # directory levels below it, so the pattern's own depth minus one is the depth
  # that stops exactly at the deepest match.
  resolvePattern = pattern:
    let
      # A literal (non-glob) member names its own directory, which sits above
      # everything `walkDirectories` yields for that base.
      literal = lib.removeSuffix "/" pattern;
      regex = patternToRegex literal;
      base = patternBaseDir literal;
      baseDepth = if base == null then 0 else lib.length (lib.splitString "/" base);
      depth = lib.max 0 ((lib.length (lib.splitString "/" literal) - baseDepth) - 1);
      candidates = walkDirectories base depth ++ [ literal ];
    in
    builtins.filter (candidate: lib.match regex candidate != null && exists "${candidate}/Cargo.toml") candidates;

  # A `members` pattern that matches nothing is a broken workspace declaration
  # and must fail loudly. Cargo rejects it too.
  resolveMembers = patterns:
    let
      resolve = pattern:
        let
          matches = resolvePattern pattern;
        in
        if matches == [ ] then
          throw "workspace-manifests: workspace member pattern '${pattern}' resolved to no directory containing a Cargo.toml under ${rootString}"
        else
          matches;
    in
    lib.unique (lib.concatMap resolve patterns);

  # `exclude` entries are not globs. Cargo compares each entry against a
  # glob-expanded member as a plain path: `crates/*` and `crates/**` exclude
  # nothing (verified against cargo 1.97 `cargo metadata`), while `crates/one/`,
  # `crates/two` and `.` exclude by exact path or ancestry. An entry that matches
  # nothing is legal — that is how a removed or archived path stays excluded.
  normaliseExclude = entry:
    let
      trimmed = lib.removeSuffix "/" (lib.removeSuffix "/" entry);
    in
    if trimmed == "." || trimmed == "" then "" else trimmed;

  excludePrefixes = lib.unique (map normaliseExclude excludes);

  # A member is pruned when an exclude is that exact path or one of its
  # ancestors; a deeper subpath of the member does not exclude the member.
  isExcluded = member:
    lib.any (excluded: excluded == "" || member == excluded || lib.hasPrefix "${excluded}/" member) excludePrefixes;

  # Cargo resolves local `path` dependencies relative to the manifest that names
  # them, so normalise them to workspace-root-relative paths.
  #
  # `[workspace.dependencies]` is read too: a crate named there with a local
  # `path` is a real build input even when no member manifest spells out a
  # `path =` entry for it (members pull it in with `workspace = true`), and
  # cargo promotes it to a workspace member because it sits inside the
  # workspace directory.
  pathDependencies =
    manifestPath:
    let
      manifest = readManifest manifestPath;
      dir = builtins.dirOf manifestPath;
      tables = lib.map (name: manifest.${name})
        (lib.filter (name: builtins.hasAttr name manifest) [
          "dependencies"
          "dev-dependencies"
          "build-dependencies"
        ]) ++ lib.optional
        (
          manifest ? workspace && manifest.workspace ? dependencies
        )
        manifest.workspace.dependencies;
      entries = lib.concatMap builtins.attrValues tables;
      # A bare `serde = "1"` string entry is not a table at all, so keep only
      # entries that actually name a local path.
      local = lib.map (entry: entry.path) (lib.filter
        (
          entry: lib.isAttrs entry && entry ? path && lib.isString entry.path
        )
        entries);
    in
    lib.unique (map (entry: if dir == "." then entry else "${dir}/${entry}") local);

  # Breadth-first closure over manifest paths and the local crates their
  # `path` dependencies pull in; `visited` also terminates cycles between local
  # crates. `pathDependencies` yields crate directories, so each is turned into
  # its manifest before being queued.
  collectManifests =
    visited: pending:
    let
      next = builtins.filter (path: !(lib.elem path visited)) pending;
    in
    if next == [ ] then
      visited
    else
      collectManifests
        (
          visited ++ next
        )
        (lib.concatMap (crate: [ "${crate}/Cargo.toml" ]) (builtins.concatMap pathDependencies next));

  declaredMembers = resolveMembers members;

  # Cargo applies `exclude` only to glob-expanded members: a path named
  # literally in `members` is always a member, so it cannot be excluded by an
  # entry that happens to point at it.
  globExpanded = lib.unique (
    lib.concatMap (pattern: if lib.hasInfix "*" pattern then resolvePattern pattern else [ ]) members
  );

  activeMembers = builtins.filter (member: !(lib.elem member globExpanded) || !isExcluded member) declaredMembers;

  # The root manifest is a closure seed in its own right: its `path` entries in
  # `[workspace.dependencies]` resolve workspace-root-relative (its `dirOf` is
  # `.`), so seeding it tracks crates that reach the build only through that
  # table. It is added to `trackedPaths` below regardless.
  manifestPaths = collectManifests [ ] ([ "Cargo.toml" ] ++ map (member: "${member}/Cargo.toml") activeMembers);

  # Workspace-level build configuration Cargo reads while resolving and building
  # dependencies, so a future config change is never silently ignored.
  configPaths = lib.filter exists [
    ".cargo/config.toml"
    ".cargo/config"
  ];

  stylePaths = lib.filter exists [ "rustfmt.toml" ];

  trackedPaths = lib.unique (manifestPaths ++ configPaths ++ stylePaths ++ [ "Cargo.lock" ]);
in

{
  source = lib.fileset.toSource {
    root = workspaceRoot;
    fileset = lib.fileset.unions (map optionalFile trackedPaths);
  };
  inherit manifestPaths activeMembers trackedPaths;
}
