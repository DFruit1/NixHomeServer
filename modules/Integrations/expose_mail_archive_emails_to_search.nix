{ config, lib, options, vars, ... }:

{
  config = lib.optionalAttrs
    (
      lib.hasAttrByPath [ "repo" "search" ] options
      && lib.hasAttrByPath [ "repo" "mailArchiveUi" ] options
      && lib.hasAttrByPath [ "services" "mail-archive-ui" "enable" ] options
    )
    (lib.mkIf (config.repo.search.enable && config.services.mail-archive-ui.enable) {
      repo.search.sources.mail-archive = {
        displayName = "Mail";
        sourceType = "mail-archive";
        aclGroup = "mail-archive-users";
        appBase = "https://emails.${vars.domain}";
        settings = {
          sharedRoot = config.repo.mailArchiveUi.paths.sharedEmailsRoot;
          usersRoot = vars.usersRoot;
        };
      };

      # The indexer reads archived .eml files from the shared and per-user
      # _Emails roots.
      users.users.search.extraGroups = lib.mkAfter [ "mail-archive-ui" ];
    });
}
