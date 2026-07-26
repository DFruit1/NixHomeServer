{ config, lib, ... }:

{
  config = lib.mkIf config.repo.attic.enable {
    users.groups.atticd = { };
    users.users.atticd = {
      isSystemUser = true;
      group = "atticd";
      home = "/var/lib/atticd";
    };

    # /var/lib/atticd is an impermanence bind mount. DynamicUser tries to manage
    # StateDirectory through a private backing directory, which conflicts with
    # that mount during activation. A stable system identity lets systemd use the
    # persisted directory directly.
    systemd.services.atticd.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "atticd";
      Group = "atticd";
    };
  };
}
