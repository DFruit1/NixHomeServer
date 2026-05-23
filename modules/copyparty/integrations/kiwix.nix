{ config, lib, pkgs, vars, ... }:

{
  config = lib.mkIf
    (
      config.nixhomeserver.apps.copyparty.enable
      && config.nixhomeserver.apps.kiwix.enable
    )
    {
      services.kiwixServe.extraUploadUsers = lib.mkAfter [
        "upload-processor"
      ];

      services.uploadProcessor = {
        extraEnvironment = {
          UPLOAD_KIWIX_LIBRARY_ROOT = vars.kiwixLibraryRoot;
          UPLOAD_ZIM_PROMOTION_USERS = vars.kanidmAdminUser;
        };
        extraReadWritePaths = [
          vars.kiwixLibraryRoot
        ];
        extraRuntimeInputs = [
          pkgs.kiwix-tools
        ];
      };

      users.users.upload-processor.extraGroups = lib.mkAfter [
        "kiwix"
      ];
    };
}
