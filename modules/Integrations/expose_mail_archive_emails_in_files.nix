{ config, lib, options, ... }:

let
  mailArchivePresent =
    lib.hasAttrByPath [ "repo" "mailArchiveUi" ] options
    && lib.hasAttrByPath [ "services" "mail-archive-ui" "enable" ] options;
  filesPresent = lib.hasAttrByPath [ "repo" "files" ] options;
in
{
  config = lib.optionalAttrs
    (
      mailArchivePresent
      && filesPresent
    )
    (lib.mkIf config.services.mail-archive-ui.enable {
      services.mail-archive-ui.visibleMirrorReadGroup = lib.mkDefault "filestash";

      systemd.services.mail-archive-ui-storage-layout-v1.script = lib.mkAfter ''
        setfacl \
          -m 'g:filestash:r-x' \
          -m 'd:g:filestash:r-x' \
          '${config.repo.mailArchiveUi.paths.sharedEmailsRoot}'
      '';
    });
}
