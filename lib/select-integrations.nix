{ lib }:
definitions: enabledApps:
builtins.filter
  (entry: lib.all (name: builtins.elem name enabledApps) entry.allApps
    && (entry.anyApps == [ ] || lib.any (name: builtins.elem name enabledApps) entry.anyApps))
  definitions
