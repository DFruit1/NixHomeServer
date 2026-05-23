{ config, lib, vars, ... }:

let
  paperlessPort = vars.networking.ports.paperless;
  dataDir = "/var/lib/paperless";
  paperlessHost = "paperless.${vars.domain}";
  blockedOfficeExtensions = [
    "doc"
    "dot"
    "docm"
    "dotm"
    "xls"
    "xlt"
    "xlsm"
    "xltm"
    "xlsb"
    "ppt"
    "pps"
    "pot"
    "pptx"
    "ppsx"
    "potx"
    "pptm"
    "ppsm"
    "potm"
    "sldm"
    "ods"
    "odp"
  ];
  mkCaseInsensitiveExtensionPattern =
    extension:
    "*."
    + lib.concatMapStrings
      (
        char:
        let
          lower = lib.toLower char;
          upper = lib.toUpper char;
        in
        if lower == upper then char else "[${lower}${upper}]"
      )
      (lib.stringToCharacters extension);
  paperlessConsumerIgnorePatterns = [
    ".DS_Store"
    ".DS_STORE"
    "._*"
    ".stfolder/*"
    ".stversions/*"
    ".localized/*"
    "desktop.ini"
    "@eaDir/*"
    "Thumbs.db"
  ] ++ map mkCaseInsensitiveExtensionPattern blockedOfficeExtensions;
in
{
  imports = [
    ./package.nix
  ];

  config = {
    services.paperless.environmentFile = "/run/paperless-oidc.env";

    services.paperless = {
      enable = true;
      configureTika = true;
      dataDir = dataDir;
      mediaDir = vars.paperlessArchiveRoot;
      consumptionDir = vars.paperlessInboxRoot;
      address = vars.networking.loopbackIPv4;
      port = paperlessPort;
      exporter = {
        enable = true;
        directory = vars.paperlessExportRoot;
        onCalendar = "02:00";
      };

      settings = {
        PAPERLESS_SOCIAL_LOGIN_ENABLED = "true";
        PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS = "true";
        PAPERLESS_SOCIAL_AUTO_SIGNUP = "true";
        PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS = "true";
        PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS_CLAIM = "groups";
        PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
        PAPERLESS_URL = "https://${paperlessHost}";
        PAPERLESS_ALLOWED_HOSTS = paperlessHost;
        PAPERLESS_EXPORT_DIR = vars.paperlessExportRoot;
        PAPERLESS_OCR_LANGUAGE = "eng";
        PAPERLESS_OCR_CLEAN = "clean";
        PAPERLESS_OCR_OUTPUT_TYPE = "pdfa";
        PAPERLESS_CONSUMER_INOTIFY_DELAY = "2";
        PAPERLESS_CONSUMER_IGNORE_PATTERNS = paperlessConsumerIgnorePatterns;
      };
    };

    systemd.timers.paperless-stale-reference-check = {
      description = "Regularly report Paperless stale file references";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        AccuracySec = "1h";
        RandomizedDelaySec = "30m";
        Persistent = true;
        Unit = "paperless-stale-reference-check.service";
      };
    };

    systemd.services.paperless-stale-reference-check = {
      description = "Report Paperless missing, inaccessible, corrupt, and orphaned files";
      after = [
        "paperless-web.service"
        "paperless-storage-layout-v1.service"
        "data-pool-layout.service"
      ];
      wants = [
        "paperless-web.service"
        "paperless-storage-layout-v1.service"
        "data-pool-layout.service"
      ];
      unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
      path = [ config.services.paperless.manage ];
      script = ''
        set -euo pipefail

        paperless-manage document_sanity_checker
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "paperless";
        Group = "paperless";
        WorkingDirectory = dataDir;
      };
    };
  };
}
