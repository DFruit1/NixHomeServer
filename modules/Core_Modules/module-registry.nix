{ lib, ... }:

{
  options.nixhomeserver.modules = lib.mkOption {
    type = lib.types.attrsOf lib.types.bool;
    default = { };
    internal = true;
    description = ''
      Evaluation-time inventory of optional application modules imported by
      this host. Application default modules register exactly one key here so
      core policy can remain independent of optional applications.
    '';
  };
}
