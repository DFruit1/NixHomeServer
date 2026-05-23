{ config, lib, vars, ... }:

{
  config = lib.mkIf
    (
      config.nixhomeserver.apps."mail-archive-ui".enable
      && config.nixhomeserver.apps.files.enable
    )
    {
      services.mail-archive-ui.visibleMirrorReadGroup = lib.mkDefault "filestash";

      systemd.services.mail-archive-ui-storage-layout-v1.script = lib.mkAfter ''
        setfacl \
          -m 'g:filestash:r-x' \
          -m 'd:g:filestash:r-x' \
          '${vars.sharedEmailsRoot}'
      '';
    };
}
