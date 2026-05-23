{ config, lib, vars, ... }:

{
  config = lib.mkIf
    (
      config.nixhomeserver.apps.paperless.enable
      && config.nixhomeserver.apps.copyparty.enable
    )
    {
      systemd.services.paperless-storage-layout-v1 = {
        before = [ "copyparty.service" ];
        script = lib.mkAfter ''
          install -d -m 0700 -o copyparty -g copyparty '${vars.paperlessArchiveRoot}/.hist'
        '';
      };
    };
}
