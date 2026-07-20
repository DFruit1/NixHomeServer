{ lib }:

{
  # Path values used by root-run storage services deliberately accept a small,
  # portable character set. This prevents traversal, systemd word splitting,
  # tmpfiles specifiers, and control characters while retaining the names used
  # by all repository modules (including dot-prefixed internal directories).
  validPathComponent = component:
    builtins.isString component
    && component != ""
    && component != "."
    && component != ".."
    && builtins.match "[A-Za-z0-9._-]+" component != null;

  validRelativePath = path:
    builtins.isString path
    && path != ""
    && !(lib.hasPrefix "/" path)
    && builtins.all
      (component:
        component != ""
        && component != "."
        && component != ".."
        && builtins.match "[A-Za-z0-9._-]+" component != null)
      (lib.splitString "/" path);

  validAbsolutePath = path:
    builtins.isString path
    && path != "/"
    && lib.hasPrefix "/" path
    && builtins.all
      (component:
        component != ""
        && component != "."
        && component != ".."
        && builtins.match "[A-Za-z0-9._-]+" component != null)
      (lib.splitString "/" (lib.removePrefix "/" path));

  validDiskId = diskId:
    builtins.isString diskId
    && diskId != ""
    && diskId != "."
    && diskId != ".."
    && builtins.match "[^/[:space:]]+" diskId != null
    && builtins.match ".*CHANGE_ME.*" diskId == null;

  validZpoolName = name:
    builtins.isString name
    && builtins.match "[A-Za-z][A-Za-z0-9_.-]*" name != null
    && builtins.stringLength name <= 255
    && builtins.match "c[0-9].*" name == null
    && builtins.all (prefix: !(lib.hasPrefix prefix name)) [
      "draid"
      "log"
      "mirror"
      "raidz"
      "spare"
    ];

  # ZFS pool GUIDs are unsigned 64-bit decimal values and can exceed Nix's
  # signed integer range, so configured identities must remain strings.  For
  # a 20-digit value the leading digit can only be 1; the remaining 19-digit
  # suffix is small enough to compare safely as a Nix integer.
  validZpoolGuid = guid:
    guid == null
    || (
      builtins.isString guid
      && builtins.match "[1-9][0-9]*" guid != null
      && builtins.stringLength guid <= 20
      && (
        builtins.stringLength guid < 20
        || (
          builtins.substring 0 1 guid == "1"
          && (
            builtins.match "[0-7]" (builtins.substring 1 1 guid) != null
            || (
              builtins.substring 1 1 guid == "8"
              && builtins.fromJSON (builtins.substring 1 19 guid) <= 8446744073709551615
            )
          )
        )
      )
    );
}
