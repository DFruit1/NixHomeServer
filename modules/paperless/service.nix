{ lib, vars, ... }:

let
  paperlessPort = vars.networking.ports.paperless;
  dataDir = "/var/lib/paperless";
  blockedOfficeExtensions = lib.optionals (!vars.paperlessEnableDangerousMacroOfficeParsing) [
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
  services.paperless.environmentFile = "/run/paperless-oidc.env";

  users.users.paperless = {
    isSystemUser = true;
    group = "paperless";
    home = dataDir;
  };

  users.groups.paperless = { };

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
      PAPERLESS_URL = "https://${vars.paperlessDomain}";
      PAPERLESS_ALLOWED_HOSTS = vars.paperlessDomain;
      PAPERLESS_EXPORT_DIR = vars.paperlessExportRoot;
      PAPERLESS_OCR_LANGUAGE = vars.paperlessOcrLanguage;
      PAPERLESS_OCR_CLEAN = "clean";
      PAPERLESS_OCR_OUTPUT_TYPE = "pdfa";
      PAPERLESS_CONSUMER_INOTIFY_DELAY = "2";
      PAPERLESS_CONSUMER_IGNORE_PATTERNS = paperlessConsumerIgnorePatterns;
    };
  };

  systemd.tmpfiles.rules = [ ];
}
