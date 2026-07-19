{ config, lib, options, ... }:

{
  config = lib.optionalAttrs (
    lib.hasAttrByPath [ "repo" "mailArchiveUi" ] options
    && lib.hasAttrByPath [ "repo" "files" ] options
  ) {
    services.mail-archive-ui.visibleMirrorReadGroup = lib.mkDefault "filestash";

    systemd.services.mail-archive-ui-storage-layout-v1.script = lib.mkAfter ''
      setfacl \
        -m 'g:filestash:r-x' \
        -m 'd:g:filestash:r-x' \
        '${config.repo.mailArchiveUi.paths.sharedEmailsRoot}'
    '';
  };
}
