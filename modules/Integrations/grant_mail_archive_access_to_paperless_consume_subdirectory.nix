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
        inbox='${config.repo.paperless.paths.inbox}'
        staging='${config.repo.paperless.paths.handoffStaging}'
        consume_subdir="$inbox/mail-archive"

        install -d -m 2770 -o root -g paperless "$consume_subdir"
        setfacl -m u:mail-archive-ui:--x "$inbox"
        setfacl -m u:mail-archive-ui:rwx -m d:u:mail-archive-ui:rwx "$consume_subdir"
        setfacl -m u:mail-archive-ui:rwx "$staging"
      '';
    });
}
