{ config, lib, options, ... }:

let
  mailArchivePresent =
    lib.hasAttrByPath [ "repo" "mailArchiveUi" ] options
    && lib.hasAttrByPath [ "services" "mail-archive-ui" "enable" ] options;
  paperlessPresent = lib.hasAttrByPath [ "repo" "paperless" ] options;
in
{
  config = lib.optionalAttrs
    (
      mailArchivePresent
      && paperlessPresent
    )
    (lib.mkIf config.services.mail-archive-ui.enable {
      systemd.services.paperless-storage-layout-v1.script = lib.mkAfter ''
        setfacl -x u:mail-archive-ui '${config.repo.paperless.paths.inbox}' 2>/dev/null || true
      '';
    });
}
