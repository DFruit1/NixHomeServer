{ config, lib, vars, ... }:

{
  config = lib.mkIf
    (
      config.nixhomeserver.apps."mail-archive-ui".enable
      && config.nixhomeserver.apps.paperless.enable
    )
    {
      services.mail-archive-ui = {
        paperlessConsumeRoot = lib.mkDefault vars.paperlessInboxRoot;
        paperlessHandoffStagingRoot = lib.mkDefault vars.paperlessHandoffStagingRoot;
      };

      users.users.mail-archive-ui.extraGroups = lib.mkAfter [
        "paperless"
      ];
    };
}
