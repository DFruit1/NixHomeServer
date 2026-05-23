{ config, lib, vars, ... }:

{
  config = lib.mkIf
    (
      config.nixhomeserver.apps.paperless.enable
      && config.nixhomeserver.apps."mail-archive-ui".enable
    )
    {
      systemd.services.paperless-storage-layout-v1.script = lib.mkAfter ''
        setfacl -x u:mail-archive-ui '${vars.paperlessInboxRoot}' 2>/dev/null || true
      '';
    };
}
