{ lib }:

let
  appNames = [
    "audiobookshelf"
    "copyparty"
    "filebrowser-quantum"
    "filestash"
    "immich"
    "jellyfin"
    "kavita"
    "kiwix"
    "mail-archive"
    "mail-archive-ui"
    "metube"
    "paperless"
    "vaultwarden"
  ];
in
rec {
  profiles = {
    # Core_Modules are intentionally fixed platform pieces. The core profile is
    # always implied by the host module and does not swap out those modules.
    core = [ ];
    files = [
      "copyparty"
      "filebrowser-quantum"
    ];
    media = [
      "audiobookshelf"
      "immich"
      "jellyfin"
      "kavita"
      "kiwix"
      "metube"
    ];
    documents = [
      "mail-archive"
      "mail-archive-ui"
      "paperless"
    ];
    ops = [
      "vaultwarden"
    ];
    compatibility = appNames;
  };

  inherit appNames;

  profileNames = [
    "core"
    "files"
    "media"
    "documents"
    "ops"
    "compatibility"
  ];

  externalSecrets = [
    "netbirdSetupKey"
    "cfHomeCreds"
    "cfAPIToken"
    "virusTotalApiKey"
  ];

  placeholderPrefixes = [
    "CHANGE_ME"
    "example."
  ];

  profileApps = profileList:
    lib.unique (lib.concatMap (profile: lib.attrByPath [ profile ] [ ] profiles) profileList);
}
