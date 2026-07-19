{ lib }:

{
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
}
