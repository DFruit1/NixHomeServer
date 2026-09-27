{ lib, vars, ... }:

{
  options.repo.ipfs.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable the private IPFS distribution service when its module is imported.";
  };

  options.repo.ipfs = {
    paths = {
      stateDir = lib.mkOption {
        type = lib.types.str;
        default = "${vars.dataRoot}/ipfs";
        description = "Persistent Kubo blockstore, node identity, and pins.";
      };
      distributionDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/ipfs-distribution";
        description = "Persistent names of admin-published IPFS content.";
      };
    };
    publisher = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/run/current-system/sw/bin/ipfs-publish";
      description = "Admin command used by integrations to pin and publish content.";
    };
  };
}
