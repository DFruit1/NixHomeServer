{ config, lib, pkgs, vars, ... }:

{
  services.kiwixServe.extraUploadUsers = lib.mkAfter [
    "upload-processor"
  ];

  services.uploadProcessor = {
    extraEnvironment = {
      UPLOAD_KIWIX_LIBRARY_ROOT = config.services.kiwixServe.libraryRoot;
      UPLOAD_ZIM_PROMOTION_USERS = vars.kanidmAdminUser;
    };
    extraReadWritePaths = [
      config.services.kiwixServe.libraryRoot
    ];
    extraRuntimeInputs = [
      pkgs.kiwix-tools
    ];
  };

  users.users.upload-processor.extraGroups = lib.mkAfter [
    "kiwix"
  ];
}
