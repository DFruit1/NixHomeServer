{ appPackages, config, lib, oauth2Proxy, pkgs, vars, ... }:

let
  renderShell = import ../../../lib/render-shell-template.nix { inherit lib; };
  serviceUser = "homepage";
  serviceGroup = "homepage";
  listenAddress = vars.networking.loopbackIPv4;
  listenPort = vars.networking.ports.homepage;
  host = "homepage.${vars.domain}";

  photosHost = "photos.${vars.domain}";
  paperlessHost = "paperless.${vars.domain}";
  audiobooksHost = "audiobooks.${vars.domain}";
  videosHost = "videos.${vars.domain}";
  booksHost = "books.${vars.domain}";
  wikiHost = "wiki.${vars.domain}";
  rssHost = "rss.${vars.domain}";
  emailsHost = "emails.${vars.domain}";
  backupsHost = vars.kopiaDomain;
  mediaManagerHost = "media.${vars.domain}";
  syncthingHost = "syncthing.${vars.domain}";
  offlineMediaCfg = vars.offlineMedia;
  offlineMediaAccessGroupRaw = offlineMediaCfg.accessGroup or "users";
  offlineMediaAccessGroup =
    if builtins.isString offlineMediaAccessGroupRaw then
      offlineMediaAccessGroupRaw
    else
      "invalid-offline-media-access-group";
  offlineMediaRequiredAllGroups = [ "users" ];
  offlineMediaRequiredAnyGroups = [ offlineMediaAccessGroup ];
  offlineMediaLoginNotes =
    if offlineMediaAccessGroup == "users" then
      "Requires baseline users membership; connect each computer or phone once while it is on the home network. Syncthing only syncs while the device is on the home LAN, so sync never uses mobile data."
    else
      "Requires baseline users membership plus ${offlineMediaAccessGroup}; connect each computer or phone once while it is on the home network. Syncthing only syncs while the device is on the home LAN, so sync never uses mobile data.";
  filesWebAccessGroup = vars.fileAccess.webAccessGroup or "files-personal-users";
  filesSftpAccessGroup = vars.fileAccess.sftpAccessGroup or "files-sftp-users";
  filesSharedAccessGroup = vars.fileAccess.sharedAccessGroup or "files-shared-users";
  filesDeleteSharedAccessGroup = vars.fileAccess.deleteSharedAccessGroup or "delete_shared_files";
  filesUsbAccessGroup = vars.fileAccess.usbAccessGroup or "usb-access";
  backupStorageAccessGroup = vars.backupStorageGroup;
  filesUsbMountName = vars.fileAccess.usbMountName or "_USB";
  filesSharedMountName = vars.fileAccess.sharedMountName or "_Shared";
  backupStorageMountName = vars.backupAccess.storageMountName or "_Backups";
  homepageAccessGroups = lib.unique [
    "users"
    filesWebAccessGroup
    filesSftpAccessGroup
    filesSharedAccessGroup
    filesUsbAccessGroup
    backupStorageAccessGroup
  ];
  sftpAccessGroups = lib.unique [
    filesWebAccessGroup
    filesSftpAccessGroup
    filesSharedAccessGroup
    filesUsbAccessGroup
    backupStorageAccessGroup
  ];
  megaEnabled = vars.rcloneMega.enable or false;
  offlineMediaEnabled =
    (config.nixhomeserver.modules."offline-music" or false)
    && (offlineMediaCfg.enable or false);
  mkvmakerEnabled = config.nixhomeserver.modules.mkvmaker or false;
  offlineMediaStateDir = offlineMediaCfg.stateDir or "/persist/appdata/offline-media";
  offlineMediaStateFile = "${offlineMediaStateDir}/devices.json";
  offlineMediaModel = (import ../../../lib/offline-media.nix { inherit lib; }) offlineMediaCfg;
  offlineMediaFolderSpecs = offlineMediaModel.folderSpecs;
  offlineMediaFolderSpecsJson = builtins.toJSON offlineMediaFolderSpecs;
  offlineMediaStateValidationJq = ''
    def valid_username:
      type == "string"
      and test("^[a-z][a-z0-9._-]{0,63}$");
    def valid_device:
      if type != "object" then false
      else
        (.deviceId | type == "string" and test("^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$"))
        and (.deviceName | type == "string" and test("^[A-Za-z0-9._ -]{1,64}$"))
      end;
    def valid_user:
      if type != "object" or ((.devices // null) | type) != "array" then false
      else all(.devices[]; valid_device)
      end;
    if type != "object" or .version != 2 or ((.users // null) | type) != "object" then false
    else all(.users | to_entries[]; (.key | valid_username) and (.value | valid_user))
    end
  '';
  syncthingDataDir = "/var/lib/syncthing";
  syncthingConfigDir = "/var/lib/syncthing/.config/syncthing";
  serverLanHost = "${vars.network.hostname}.${vars.networking.dns.lanDomain}";
  kanidmGroups = lib.sort (a: b: a < b) (
    builtins.filter
      (group: !(lib.hasPrefix "idm_" group) && group != "system_admins" && group != "domain_admins")
      (builtins.attrNames (config.services.kanidm.provision.groups or { }))
  );
  kanidmGroupDescriptions = (config.nixhomeserver or { }).kanidmGroupDescriptions or { };
  kanidmGroupManagement = lib.mapAttrs
    (_: group:
      if !(group.overwriteMembers or true) then
        "manual"
      else
        "identity.appUsers")
    (config.services.kanidm.provision.groups or { });

  caddyHosts = config.services.caddy.virtualHosts;
  hostEnabled = name: builtins.hasAttr name caddyHosts;

  immichEnabled = hostEnabled photosHost;
  paperlessEnabled = hostEnabled paperlessHost;
  audiobookshelfEnabled = hostEnabled audiobooksHost;
  filesSftpEnabled = builtins.hasAttr "files-sftp-sshd" config.systemd.services;
  jellyfinEnabled = hostEnabled videosHost;
  offlineMediaEnabledForHomepage = offlineMediaEnabled;
  kavitaEnabled = hostEnabled booksHost;
  kiwixEnabled = hostEnabled wikiHost;
  freshrssEnabled = hostEnabled rssHost;
  mailArchiveEnabled = hostEnabled emailsHost;
  mediaManagerEnabled = hostEnabled mediaManagerHost;
  kopiaEnabled = hostEnabled backupsHost;
  personalPath = relativePath: "/${relativePath}";
  sharedPath = relativePath: "/${vars.fileAccess.sharedMountName}/${relativePath}";
  sftpAuthorizedKeysDir = "/persist/appdata/files-sftp-authorized-keys";
  vaultRuntimeDir = "/run/homepage-vault";
  deploySettingsDir = "/var/lib/deploy-settings";
  buildModeStateFile = "${deploySettingsDir}/build-mode.json";
  nixBuildModeApply = pkgs.writeShellScript "homepage-nix-build-mode-apply" (renderShell ../../../custom_apps/shell/homepage/homepage-nix-build-mode-apply.sh.in {
    BUILDMODESTATEFILE_QUOTED = lib.escapeShellArg buildModeStateFile;
    COREUTILS = pkgs.coreutils;
    JQ = pkgs.jq;
  });
  powerScheduleCfg = config.nixhomeserver.powerSchedule;
  powerScheduleApply = pkgs.writeShellScript "homepage-power-schedule-apply" (renderShell ../../../custom_apps/shell/homepage/homepage-power-schedule-apply.sh.in {
    POWERSCHEDULECFG_STATEFILE_QUOTED = lib.escapeShellArg powerScheduleCfg.stateFile;
    POWERSCHEDULECFG_VALIDATOR = powerScheduleCfg.validator;
    COREUTILS = pkgs.coreutils;
    JQ = pkgs.jq;
  });
  kanidmVaultUrl = "https://${vars.kanidmDomain}:${toString vars.networking.ports.kanidm}";
  installSftpKey = pkgs.writeShellScript "homepage-install-sftp-key" (renderShell ../../../custom_apps/shell/homepage/homepage-install-sftp-key.sh.in {
    GNUGREP = pkgs.gnugrep;
    COREUTILS = pkgs.coreutils;
    GNUSED = pkgs.gnused;
    OPENSSH = pkgs.openssh;
    SFTPAUTHORIZEDKEYSDIR_QUOTED = lib.escapeShellArg sftpAuthorizedKeysDir;
    SFTPAUTHORIZEDKEYSDIR = sftpAuthorizedKeysDir;
    UTIL_LINUX = pkgs.util-linux;
    SFTPAUTHORIZEDKEYSDIR_SERVICEUSER_XXXXXX_QUOTED = lib.escapeShellArg "${sftpAuthorizedKeysDir}/.${serviceUser}.XXXXXX";
  });
  showSyncthingDeviceId = pkgs.writeShellScript "homepage-show-syncthing-device-id" (renderShell ../../../custom_apps/shell/homepage/homepage-show-syncthing-device-id.sh.in {
    SYNCTHING = pkgs.syncthing;
    SYNCTHINGCONFIGDIR_QUOTED = lib.escapeShellArg syncthingConfigDir;
    SYNCTHINGDATADIR_QUOTED = lib.escapeShellArg syncthingDataDir;
  });
  vaultSyncthingKeyHelper = pkgs.writeShellScript "homepage-syncthing-api-key" (renderShell ../../../custom_apps/shell/homepage/homepage-syncthing-api-key.sh.in {
    SYNCTHINGCONFIGDIR_CONFIG_XML_QUOTED = lib.escapeShellArg "${syncthingConfigDir}/config.xml";
    COREUTILS = pkgs.coreutils;
    GNUGREP = pkgs.gnugrep;
    LIBXML2 = pkgs.libxml2;
    OPENSSL = pkgs.openssl;
    UTIL_LINUX = pkgs.util-linux;
    SYSTEMD = pkgs.systemd;
    PYTHON3 = pkgs.python3;
    CURL = pkgs.curl;
  });
  sftpKeyListHelper = pkgs.writeShellScript "homepage-sftp-key-list" (renderShell ../../../custom_apps/shell/homepage/homepage-sftp-key-list.sh.in {
    GNUGREP = pkgs.gnugrep;
    SFTPAUTHORIZEDKEYSDIR_QUOTED = lib.escapeShellArg sftpAuthorizedKeysDir;
    COREUTILS = pkgs.coreutils;
    OPENSSH = pkgs.openssh;
  });
  freshrssApiPasswordHelper = pkgs.writeShellScript "homepage-freshrss-api-password" (renderShell ../../../custom_apps/shell/homepage/homepage-freshrss-api-password.sh.in {
    GNUGREP = pkgs.gnugrep;
    COREUTILS = pkgs.coreutils;
    CONFIG_REPO_FRESHRSS_STATEDIR_QUOTED = lib.escapeShellArg config.repo.freshrss.stateDir;
    UTIL_LINUX = pkgs.util-linux;
    CONFIG_SERVICES_FRESHRSS_PACKAGE = config.services.freshrss.package;
  });
  kavitaApiKeysHelper = pkgs.writeShellScript "homepage-kavita-keys" (renderShell ../../../custom_apps/shell/homepage/homepage-kavita-keys.sh.in {
    GNUGREP = pkgs.gnugrep;
    COREUTILS = pkgs.coreutils;
    PYTHON3 = pkgs.python3;
    VAR_LIB_KAVITA_CONFIG_KAVITA_DB_QUOTED = lib.escapeShellArg "/var/lib/kavita/config/kavita.db";
    CONFIG_AGE_SECRETS_KAVITATOKENKEY_PATH_QUOTED = lib.escapeShellArg config.age.secrets.kavitaTokenKey.path;
    HTTP_VARS_NETWORKING_LOOPBACKIPV4_TOSTRING_VARS_NETWORKING_PORTS_KAVITA_QUOTED = lib.escapeShellArg "http://${vars.networking.loopbackIPv4}:${toString vars.networking.ports.kavita}";
  });
  offlineMediaStatus = pkgs.writeShellScript "homepage-offline-media-status" (renderShell ../../../custom_apps/shell/homepage/homepage-offline-media-status.sh.in {
    GNUGREP = pkgs.gnugrep;
    OFFLINEMEDIASTATEFILE_QUOTED = lib.escapeShellArg offlineMediaStateFile;
    OFFLINEMEDIAFOLDERSPECSJSON_QUOTED = lib.escapeShellArg offlineMediaFolderSpecsJson;
    VARS_USERSROOT_QUOTED = lib.escapeShellArg vars.usersRoot;
    JQ = pkgs.jq;
    OFFLINEMEDIASTATEVALIDATIONJQ = offlineMediaStateValidationJq;
    COREUTILS = pkgs.coreutils;
    LIBXML2 = pkgs.libxml2;
    SYNCTHINGCONFIGDIR_QUOTED = lib.escapeShellArg syncthingConfigDir;
    CURL = pkgs.curl;
  });
  offlineMediaEnroll = pkgs.writeShellScript "homepage-offline-media-enroll" (renderShell ../../../custom_apps/shell/homepage/homepage-offline-media-enroll.sh.in {
    GNUGREP = pkgs.gnugrep;
    COREUTILS = pkgs.coreutils;
    JQ = pkgs.jq;
    SHOWSYNCTHINGDEVICEID = showSyncthingDeviceId;
    OFFLINEMEDIASTATEDIR_QUOTED = lib.escapeShellArg offlineMediaStateDir;
    OFFLINEMEDIASTATEFILE_QUOTED = lib.escapeShellArg offlineMediaStateFile;
    OFFLINEMEDIAFOLDERSPECSJSON_QUOTED = lib.escapeShellArg offlineMediaFolderSpecsJson;
    VARS_USERSROOT_QUOTED = lib.escapeShellArg vars.usersRoot;
    UTIL_LINUX = pkgs.util-linux;
    CONFIG_AGE_SECRETS_KANIDMADMINPASS_PATH = config.age.secrets.kanidmAdminPass.path;
    KANIDM_1_11 = pkgs.kanidm_1_11;
    HTTPS_VARS_KANIDMDOMAIN_TOSTRING_VARS_NETWORKING_PORTS_KANIDM_QUOTED = lib.escapeShellArg "https://${vars.kanidmDomain}:${toString vars.networking.ports.kanidm}";
    OFFLINEMEDIAACCESSGROUP_QUOTED = lib.escapeShellArg offlineMediaAccessGroup;
    OFFLINEMEDIASTATEVALIDATIONJQ = offlineMediaStateValidationJq;
    SYSTEMD = pkgs.systemd;
    ACL = pkgs.acl;
    FINDUTILS = pkgs.findutils;
    LIBXML2 = pkgs.libxml2;
    SYNCTHINGCONFIGDIR_QUOTED = lib.escapeShellArg syncthingConfigDir;
    CURL = pkgs.curl;
    OFFLINEMEDIASTATUS = offlineMediaStatus;
  });
  offlineMediaRemove = pkgs.writeShellScript "homepage-offline-media-remove" (renderShell ../../../custom_apps/shell/homepage/homepage-offline-media-remove.sh.in {
    GNUGREP = pkgs.gnugrep;
    OFFLINEMEDIASTATEDIR_QUOTED = lib.escapeShellArg offlineMediaStateDir;
    OFFLINEMEDIASTATEFILE_QUOTED = lib.escapeShellArg offlineMediaStateFile;
    OFFLINEMEDIAFOLDERSPECSJSON_QUOTED = lib.escapeShellArg offlineMediaFolderSpecsJson;
    UTIL_LINUX = pkgs.util-linux;
    COREUTILS = pkgs.coreutils;
    JQ = pkgs.jq;
    OFFLINEMEDIASTATEVALIDATIONJQ = offlineMediaStateValidationJq;
    LIBXML2 = pkgs.libxml2;
    SYNCTHINGCONFIGDIR_QUOTED = lib.escapeShellArg syncthingConfigDir;
    CURL = pkgs.curl;
    SYSTEMD = pkgs.systemd;
    OFFLINEMEDIASTATUS = offlineMediaStatus;
  });

  catalog = import ../../catalog.nix;
  registeredCards = lib.concatMap
    (entry: entry.registration.homepage { inherit config vars; })
    (lib.attrValues catalog.apps);
  coreCards = [
    {
      order = 10;
      id = "offline-media";
      name = "Offline Media";
      url = "/services/offline-media";
      enabled = offlineMediaEnabledForHomepage;
      category = "media";
      description = "Automatically keep copies of your server music and videos on a computer or android phone while it is on the home network.";
      loginNotes = offlineMediaLoginNotes;
      projectUrl = "https://syncthing.net";
      logoUrl = "/logos/syncthing.svg";
      appName = "syncthing";
      uploadNotes = "Add media with the Files app first; this service then copies it to your connected devices.";
      requiredAllGroups = offlineMediaRequiredAllGroups;
      requiredAnyGroups = offlineMediaRequiredAnyGroups;
    }
    {
      order = 11;
      id = "media-manager";
      name = "Media Manager";
      url = "https://${mediaManagerHost}";
      enabled = mediaManagerEnabled;
      category = "media";
      description = "Browse, organize, and move media across shared and personal library roots.";
      loginNotes = "Use Kanidm; requires media-manager-editors for mutation permissions.";
      projectUrl = "https://github.com/user/media-manager";
      logoUrl = "/logos/media-manager.svg";
      appName = "media-manager";
      uploadNotes = "Place media in the appropriate shared or personal root folders.";
      requiredAnyGroups = [ "media-manager-editors" "users" ];
    }
    {
      order = 18;
      id = "kopia";
      name = "Kopia";
      url = "https://${backupsHost}";
      enabled = kopiaEnabled;
      category = "operations";
      description = "Kopia backup management for critical state, Paperless data, and consistent database dumps.";
      loginNotes = "Requires ${vars.backupAdminGroup} plus the native Kopia password.";
      projectUrl = "https://kopia.io";
      logoUrl = "/logos/kopia.svg";
      appName = "kopia";
      uploadNotes = "Backup repository files are managed by Kopia.";
      requiredAnyGroups = [ vars.backupAdminGroup ];
    }
  ];
  serviceCards = map
    (card: lib.filterAttrs (name: value: name != "order" && value != null) card)
    (lib.sort (a: b: a.order < b.order) config.repo.homepage.serviceCards);

  folderGuides = [
    {
      id = "documents";
      title = "Documents";
      enabled = paperlessEnabled;
      serviceIds = [ "documents" "files" "emails" ];
      fileTypes = [ "pdf" "jpg" "jpeg" "png" "tiff" "eml attachments" ];
      personalPath = personalPath "_Files";
      sharedPath = null;
      personalPathRequiredAnyGroups = [ filesWebAccessGroup filesSftpAccessGroup ];
      requiredAnyGroups = [ "paperless-users" filesWebAccessGroup "mail-archive-users" ];
      instructions = [
        "Use Paperless for scanned documents, bills, statements, receipts, and searchable PDFs."
        "Prefer PDF or image files. Convert office documents before handing them to Paperless."
        "Use Mail Archive attachment handoff when an email attachment should become a Paperless document."
        "The Paperless consume inbox is server-managed and is not exposed as a normal Files or SFTP folder."
      ];
    }
    {
      id = "photos";
      title = "Photos And Phone Media";
      enabled = immichEnabled;
      serviceIds = [ "photos" ];
      fileTypes = [ "jpg" "jpeg" "png" "heic" "webp" "mov" "mp4" ];
      personalPath = null;
      sharedPath = null;
      requiredAnyGroups = [ "immich-users" ];
      instructions = [
        "Upload through Immich web or the Immich mobile app so metadata and thumbnails are handled correctly."
        "Use the private Photos hostname for normal login."
        "Use public share links only when sending selected albums or photos to other people."
      ];
    }
    {
      id = "audio";
      title = "Audiobooks";
      enabled = audiobookshelfEnabled;
      serviceIds = [ "audiobooks" "downloads" "files" ];
      fileTypes = [ "m4b" "mp3" "flac" "opus" "m4a" "cue" "jpg" "opf" ];
      personalPath = personalPath "_Audiobooks";
      sharedPath = sharedPath "_Audiobooks";
      personalPathRequiredAnyGroups = [ filesWebAccessGroup filesSftpAccessGroup ];
      sharedPathRequiredAnyGroups = [ vars.fileAccess.sharedAccessGroup ];
      requiredAnyGroups = [ "audiobookshelf-users" "downloads-users" filesWebAccessGroup filesSftpAccessGroup ];
      instructions = [
        "Keep each audiobook in its own folder with cover art and metadata beside the audio files."
        "Use _Audiobooks/_YouTube for audio produced by the downloader."
        "Audiobook audio with its cover art belongs in Audiobookshelf, not Jellyfin."
      ];
    }
    {
      id = "videos";
      title = "Videos";
      enabled = jellyfinEnabled;
      serviceIds = [ "videos" "downloads" "files" ];
      fileTypes = [ "mkv" "mp4" "webm" "avi" "srt" "ass" "nfo" ];
      personalPath = personalPath "_Videos";
      sharedPath = sharedPath "_Videos";
      personalPathRequiredAnyGroups = [ filesWebAccessGroup filesSftpAccessGroup ];
      sharedPathRequiredAnyGroups = [ vars.fileAccess.sharedAccessGroup ];
      requiredAnyGroups = [ "jellyfin-users" "downloads-users" filesWebAccessGroup filesSftpAccessGroup ];
      instructions = [
        "Put films in _Movies and series in _Shows so Jellyfin can identify them."
        "Use _YouTube for downloader output and _Other for other videos you want synced to devices."
        "Subtitle and metadata files should live beside the matching video file."
      ];
    }
    {
      id = "offline-media";
      title = "Offline Media";
      enabled = offlineMediaEnabledForHomepage;
      serviceIds = [ "offline-media" "files" "downloads" ];
      fileTypes = [ "mp3" "flac" "m4a" "opus" "ogg" "wav" "mkv" "mp4" "webm" ];
      personalPath = "/";
      sharedPath = null;
      personalPathRequiredAnyGroups = [ filesWebAccessGroup filesSftpAccessGroup ];
      requiredAllGroups = offlineMediaRequiredAllGroups;
      requiredAnyGroups = offlineMediaRequiredAnyGroups;
      instructions = [
        "Place music files in _Music."
        "Use _Videos/_YouTube for downloaded videos and _Videos/_Other for other videos you want available offline."
        "Enroll each phone, tablet, or laptop from the Offline Media service page."
        "The server publishes folders as send-only; device-side deletes do not remove the server copy."
      ];
    }
    {
      id = "books";
      title = "Books, Comics, Manga";
      enabled = kavitaEnabled;
      serviceIds = [ "books" "files" ];
      fileTypes = [ "epub" "pdf" "cbz" "cbr" "zip" "rar" ];
      personalPath = personalPath "_Books";
      sharedPath = sharedPath "_Books";
      personalPathRequiredAnyGroups = [ filesWebAccessGroup filesSftpAccessGroup ];
      sharedPathRequiredAnyGroups = [ vars.fileAccess.sharedAccessGroup ];
      requiredAnyGroups = [ "kavita-users" filesWebAccessGroup filesSftpAccessGroup ];
      instructions = [
        "Use _Ebooks for prose books, _Comics for western comics, and _Manga for manga."
        "Keep series folders named consistently so Kavita groups volumes correctly."
        "Use archive formats such as cbz or cbr for comics and manga."
      ];
    }
    {
      id = "emails";
      title = "Email Archive";
      enabled = mailArchiveEnabled;
      serviceIds = [ "emails" "files" "documents" ];
      fileTypes = [ "eml" "zip" "attachments" ];
      personalPath = personalPath "_Emails";
      sharedPath = sharedPath "_Emails";
      personalPathRequiredAnyGroups = [ filesWebAccessGroup filesSftpAccessGroup ];
      sharedPathRequiredAnyGroups = [ vars.fileAccess.sharedAccessGroup ];
      requiredAnyGroups = [ "mail-archive-users" filesWebAccessGroup filesSftpAccessGroup ];
      instructions = [
        "Use the Mail Archive UI for search, sync, attachment download, and reindex actions."
        "Visible .eml files are mirrors for browsing; do not work inside .internal-sync."
        "Send document attachments to Paperless from the Mail Archive UI when they should be archived."
      ];
    }
    {
      id = "kiwix";
      title = "Offline Reference";
      enabled = kiwixEnabled;
      serviceIds = [ "wiki" "files" ];
      fileTypes = [ "zim" ];
      personalPath = null;
      sharedPath = null;
      requiredAnyGroups = [ "app-admin" ];
      instructions = [
        "Use complete .zim files only."
        "Kiwix library uploads are operator-managed and are not exposed through each user's Files/SFTP root."
        "After upload, the Kiwix sync service publishes valid ZIM files into the web library."
      ];
    }
  ];

  adminGuide = [
    {
      title = "Validate config & prerequisites";
      command = "nix run .#validate-config-readiness -- --identity /path/to/age.key";
      detail = "Check decryptability and deploy prerequisites. Replace the identity path.";
    }
    {
      title = "Check git is clean";
      command = "git status --short";
      detail = "Confirm all new Nix files are tracked before deploying.";
    }
    {
      title = "Quick repo checks";
      command = "./scripts/validate-repo.sh";
      detail = "Run fast policy and script tests before deploying.";
    }
    {
      title = "Test deploy";
      command = "./scripts/deploy.sh --action test";
      detail = "Test-activate the repo on the live server. Services may restart; the boot default is unchanged.";
    }
    {
      title = "Make permanent";
      command = "./scripts/deploy.sh --action switch";
      detail = "Persist the tested generation as the next boot default. Run only after checking failed units.";
    }
    {
      title = "Emergency rollback";
      command = "sudo nixos-rebuild switch --rollback";
      detail = "Server-console recovery. Bypasses deploy health checks and changes the boot profile.";
    }
    {
      title = "Failed services";
      command = "sudo systemctl --failed --no-pager";
      detail = "List failed units after deploys or incidents.";
    }
    {
      title = "Follow service logs";
      command = "journalctl -fu SERVICE.service";
      detail = "Stream one service's logs. Replace SERVICE with the real unit name.";
    }
    {
      title = "Restart a service";
      command = "sudo systemctl restart SERVICE.service";
      detail = "Restart one service. Check logs first; prefer this over host restarts.";
    }
    {
      title = "Boot warnings";
      command = "journalctl -b -p warning..alert --no-pager";
      detail = "Scan current-boot warnings and errors.";
    }
    {
      title = "Authenticate Kanidm CLI";
      command = "kanidm login -D ${lib.escapeShellArg vars.kanidmAdminUser} && kanidm self whoami";
      detail = "Start or verify a CLI session before running person or group commands.";
    }
    {
      title = "Verify user exists";
      command = "kanidm person get USERNAME";
      detail = "Check a Kanidm user before creating or changing access.";
    }
    {
      title = "Create user";
      command = "kanidm person create USERNAME 'Display Name'\nkanidm person update USERNAME --mail EMAIL";
      detail = "Create a Kanidm person and set their email for OIDC apps.";
    }
    {
      title = "Grant baseline sign-in";
      command = "kanidm group add-members users USERNAME";
      detail = "Add the user to the standard users group.";
    }
    {
      title = "Grant app access";
      command = "kanidm group add-members APP-GROUP USERNAME";
      detail = "Grant a specific app, file, or admin group. Replace APP-GROUP with the real group name.";
    }
    {
      title = "Revoke access";
      command = "kanidm group remove-members APP-GROUP USERNAME";
      detail = "Remove a specific group membership.";
    }
    {
      title = "Generate sign-in link";
      command = "kanidm person credential create-reset-token USERNAME --name ${lib.escapeShellArg vars.kanidmAdminUser}";
      detail = "One-hour, single-use link. Send through a trusted channel after access is ready.";
    }
    {
      title = "Reconcile identity";
      command = "sudo systemctl start kanidm-identity-reconcile.service kanidm-files-posix-groups.service fileshare-user-root-sync.service";
      detail = "Refresh Kanidm display names, emails, POSIX groups, and per-user roots.";
    }
  ]
  ++ lib.optionals immichEnabled [
    {
      title = "Sync Immich accounts";
      command = "sudo systemctl start immich-oidc-reconcile.service immich-admin-reconcile.service";
      detail = "Reconcile Immich users and admins from Kanidm groups.";
    }
  ]
  ++ lib.optionals paperlessEnabled [
    {
      title = "Sync Paperless accounts";
      command = "sudo systemctl start paperless-oidc-reconcile.service";
      detail = "Reconcile Paperless accounts from Kanidm after access changes.";
    }
  ]
  ++ lib.optionals jellyfinEnabled [
    {
      title = "Jellyfin initial password";
      command = "sudo jellyfin-initial-credential USERNAME";
      detail = "Retrieve the stored initial credential for a native client. Treat as a secret.";
    }
    {
      title = "Sync Jellyfin libraries";
      command = "sudo systemctl start jellyfin-library-sync.service";
      detail = "Refresh Jellyfin libraries after media changes.";
    }
    {
      title = "Troubleshoot Jellyfin LAN discovery";
      detail = "Keep the client on the same IPv4 broadcast network, disable guest-Wi-Fi or client isolation, and verify that the client accepts replies from the server's UDP source port 7359.";
    }
    {
      title = "Allow Jellyfin discovery replies with nftables";
      command = "sudo nft insert rule inet filter input iifname \"<CLIENT_LAN_INTERFACE>\" ip saddr ${vars.networking.lan.ip} udp sport 7359 counter accept comment \"Jellyfin discovery replies\"";
      detail = "Run on the Linux client after confirming its nftables table and input-chain names; persist the equivalent rule in that client's ruleset.";
    }
    {
      title = "Allow Jellyfin discovery replies with UFW";
      command = "sudo ufw allow in on <CLIENT_LAN_INTERFACE> proto udp from ${vars.networking.lan.ip} port 7359 to any comment 'Jellyfin discovery replies'";
      detail = "Run on a Linux client managed by UFW. Replace the interface placeholder before applying the rule.";
    }
    {
      title = "Allow Jellyfin discovery replies with firewalld";
      command = ''sudo firewall-cmd --permanent --zone=home --add-rich-rule='rule family="ipv4" source address="${vars.networking.lan.ip}/32" source-port port="7359" protocol="udp" accept' && sudo firewall-cmd --reload'';
      detail = "Run on a Linux client managed by firewalld after confirming that its LAN interface belongs to the home zone.";
    }
    {
      title = "Allow Jellyfin discovery replies on Windows";
      command = ''New-NetFirewallRule -DisplayName "Jellyfin discovery replies" -Direction Inbound -Action Allow -Protocol UDP -RemoteAddress ${vars.networking.lan.ip} -RemotePort 7359 -Profile Private'';
      detail = "Run in Administrator PowerShell on a Windows client whose LAN network profile is Private.";
    }
    {
      title = "Allow Jellyfin discovery on Apple devices";
      detail = "On macOS, allow Fladder under System Settings → Privacy & Security → Local Network, then ensure Block all incoming connections is off in Firewall Options. On iPhone or iPad, enable Fladder under Settings → Privacy & Security → Local Network.";
    }
  ]
  ++ lib.optionals kiwixEnabled [
    {
      title = "Sync Kiwix library";
      command = "sudo systemctl start kiwix-library-sync.service";
      detail = "Publish new or repaired ZIM files.";
    }
  ]
  ++ [
    {
      title = "Check space & disks";
      command = "df -hT\nlsblk -f";
      detail = "Mounted filesystems, free space, block devices, UUIDs, and mountpoints.";
    }
    {
      title = "Backup schedule";
      command = "systemctl list-timers 'kopia*' --all --no-pager";
      detail = "Verify Kopia snapshot timers are scheduled and see next run times.";
    }
    {
      title = "Trigger snapshot now";
      command = "sudo systemctl start kopia-persist-snapshot.service";
      detail = "Start an immediate persist snapshot. Check logs afterward.";
    }
  ]
  ++ lib.optionals megaEnabled [
    {
      title = "Run offsite sync";
      command = "sudo systemctl start rclone-mega-kopia-sync.service";
      detail = "Mirror the Kopia repository offsite.";
    }
  ]
  ++ [
    {
      title = "Reverse proxy health";
      command = "systemctl status caddy.service --no-pager";
      detail = "Check the edge reverse proxy before debugging app reachability.";
    }
    {
      title = "Firewall rules";
      command = "sudo nft list ruleset";
      detail = "Inspect active nftables rules when a service runs but traffic is blocked.";
    }
  ];

  homepageConfig = pkgs.writeText "homepage-config.json" (builtins.toJSON {
    brandName = vars.brandName;
    domain = vars.domain;
    serverLanHost = serverLanHost;
    services = serviceCards;
    kanidmGroups = kanidmGroups;
    kanidmGroupDescriptions = kanidmGroupDescriptions;
    kanidmGroupManagement = kanidmGroupManagement;
    adminUsers = [ vars.kanidmAdminUser ];
    adminGroups = [ ];
    canaryAdminUser = vars.kanidmAdminUser;
    sftp = {
      enabled = filesSftpEnabled;
      host = serverLanHost;
      port = vars.networking.ports.filesSftp;
      networkNote = "LAN-only endpoint. Connect from the home network; the public web tunnel and NetBird interface do not expose this port.";
      requiredAnyGroups = sftpAccessGroups;
      accessNotes = [
        {
          text = "Your SFTP root includes /${filesSharedMountName}, a shared household view. It is writable; server-provisioned folders starting with '_' can never be deleted, and other shared files can only be removed by members of the ${filesDeleteSharedAccessGroup} group.";
          requiredAnyGroups = [ filesSharedAccessGroup ];
        }
        {
          text = "You can delete files inside /${filesSharedMountName}, the shared household view. Server-provisioned folders starting with '_' remain protected and can never be deleted.";
          requiredAnyGroups = [ filesDeleteSharedAccessGroup ];
        }
        {
          text = "Your SFTP root includes /${filesUsbMountName} for external USB storage. It is writable but deletion-protected. Attached USB drives appear here automatically, each under a folder named after the drive; the shared view is empty while no drive is connected.";
          requiredAnyGroups = [ filesUsbAccessGroup ];
        }
        {
          text = "Your SFTP root includes /${backupStorageMountName}, a read-only view of encrypted backup repository files. You can copy files out, but cannot upload, edit, rename, or delete them; this role does not grant Kopia administration or browser Files access.";
          requiredAnyGroups = [ backupStorageAccessGroup ];
        }
      ];
    };
    offlineMedia = {
      enabled = offlineMediaEnabledForHomepage;
      requiredAllGroups = offlineMediaRequiredAllGroups;
      requiredAnyGroups = offlineMediaRequiredAnyGroups;
      connectionAddresses = [
        {
          address = "tcp://${vars.networking.lan.ip}:22000";
          label = "At home (LAN) — recommended";
          kind = "lan";
        }
        {
          address = "tcp://${syncthingHost}:22000";
          label = "Private hostname (home LAN or NetBird)";
          kind = "hostname";
        }
        {
          address = "tcp://${vars.networking.netbird.ip}:22000";
          label = "Away from home (NetBird) — optional, may use mobile data";
          kind = "netbird";
        }
      ];
      folders = [ ];
      devices = [ ];
    };
    inherit folderGuides adminGuide;
    vault = {
      enabled = true;
      kanidmBaseUrl = "https://${vars.kanidmDomain}";
      sessionTtlSeconds = 900;
      idleTtlSeconds = 300;
      freshrssWebUrl = if freshrssEnabled then "https://${rssHost}" else "";
      kavitaWebUrl = if kavitaEnabled then "https://${booksHost}" else "";
      features = {
        sshKeys = {
          enabled = filesSftpEnabled;
          requiredAnyGroups = sftpAccessGroups;
        };
        syncthingApiKey = {
          enabled = true;
          adminOnly = true;
        };
        freshrssApiPassword = {
          enabled = freshrssEnabled;
          requiredAnyGroups = [ "freshrss-users" ];
        };
        kavitaApiKeys = {
          enabled = kavitaEnabled;
          requiredAnyGroups = [ "kavita-users" ];
        };
      };
    };
  });
in
{
  options.repo.homepage.serviceCards = lib.mkOption {
    type = lib.types.listOf (import ../../../lib/homepage-card-type.nix { inherit lib; });
    default = [ ];
    description = "Application-owned Homepage cards, ordered for presentation.";
  };

  config = lib.mkMerge [
    { repo.homepage.serviceCards = registeredCards ++ coreCards; }
    {
      users.groups.${serviceGroup} = { };

      users.users.${serviceUser} = {
        isSystemUser = true;
        group = serviceGroup;
        home = "/var/lib/homepage";
        createHome = true;
      };

      systemd.services.homepage = {
        description = "Kanidm-authenticated home page";
        wantedBy = [ "multi-user.target" ];
        wants = [
          "network-online.target"
        ] ++ lib.optional offlineMediaEnabledForHomepage "data-pool-layout.service";
        after = [
          "network-online.target"
        ] ++ lib.optional offlineMediaEnabledForHomepage "data-pool-layout.service";
        environment = {
          HOMEPAGE_HOST = listenAddress;
          HOMEPAGE_PORT = toString listenPort;
          HOMEPAGE_CONFIG_FILE = homepageConfig;
          HOMEPAGE_STATIC_DIR = "${appPackages.homepage}/share/homepage/client";
          HOMEPAGE_SFTP_KEY_INSTALL_COMMAND = installSftpKey;
          HOMEPAGE_SUDO = "/run/wrappers/bin/sudo";
          HOMEPAGE_VAULT_KANIDM_URL = kanidmVaultUrl;
          HOMEPAGE_VAULT_SYNCTHING_KEY_COMMAND = vaultSyncthingKeyHelper;
        } // lib.optionalAttrs filesSftpEnabled {
          HOMEPAGE_SFTP_KEY_LIST_COMMAND = sftpKeyListHelper;
        } // lib.optionalAttrs freshrssEnabled {
          HOMEPAGE_VAULT_FRESHRSS_PASSWORD_COMMAND = freshrssApiPasswordHelper;
        } // lib.optionalAttrs kavitaEnabled {
          HOMEPAGE_VAULT_KAVITA_KEYS_COMMAND = kavitaApiKeysHelper;
        } // lib.optionalAttrs offlineMediaEnabledForHomepage {
          HOMEPAGE_SYNCTHING_DEVICE_ID_COMMAND = showSyncthingDeviceId;
          HOMEPAGE_OFFLINE_MEDIA_STATUS_COMMAND = offlineMediaStatus;
          HOMEPAGE_OFFLINE_MEDIA_ENROLL_COMMAND = offlineMediaEnroll;
          HOMEPAGE_OFFLINE_MEDIA_REMOVE_COMMAND = offlineMediaRemove;
        } // lib.optionalAttrs mkvmakerEnabled {
          HOMEPAGE_MKVMAKER_PROGRESS_FILE = "/run/mkvmaker/progress.json";
        } // lib.optionalAttrs powerScheduleCfg.available {
          HOMEPAGE_POWER_SCHEDULE_FILE = powerScheduleCfg.stateFile;
          HOMEPAGE_POWER_SCHEDULE_APPLY_COMMAND = powerScheduleApply;
          HOMEPAGE_POWER_SCHEDULE_DEFAULTS = powerScheduleCfg.defaultsJson;
        } // {
          HOMEPAGE_BUILD_MODE_FILE = buildModeStateFile;
          HOMEPAGE_BUILD_MODE_APPLY_COMMAND = nixBuildModeApply;
          HOMEPAGE_BUILD_MODE_DEFAULT = vars.buildMode;
        };
        serviceConfig = {
          Type = "simple";
          User = serviceUser;
          Group = serviceGroup;
          ExecStart = "${appPackages.homepage}/bin/homepage";
          Restart = "on-failure";
          RestartSec = "5s";
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          LockPersonality = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          SystemCallArchitectures = "native";
          # NoNewPrivileges/RestrictSUIDSGID cannot be enabled here: the
          # narrowly-scoped offline-media and SFTP helpers intentionally use
          # the sudo rules declared below.
          ReadWritePaths = [ sftpAuthorizedKeysDir vaultRuntimeDir ]
            ++ lib.optional offlineMediaEnabledForHomepage offlineMediaStateDir
            # The sudo helpers inherit homepage.service's mount namespace, so
            # offline-media enrollment needs this writable despite running as root.
            ++ lib.optional offlineMediaEnabledForHomepage vars.usersRoot
            ++ lib.optional powerScheduleCfg.available powerScheduleCfg.stateDir
            ++ [ deploySettingsDir ];
          ReadOnlyPaths = [
            homepageConfig
          ];
        };
      };

      systemd.tmpfiles.rules = [
        "d ${sftpAuthorizedKeysDir} 0755 root root -"
        "d ${vaultRuntimeDir} 0755 root root -"
        "d ${deploySettingsDir} 0755 root root -"
      ];

      security.sudo.extraRules = [
        {
          users = [ serviceUser ];
          commands = [
            {
              command = "${installSftpKey}";
              options = [ "NOPASSWD" ];
            }
            {
              command = "${vaultSyncthingKeyHelper}";
              options = [ "NOPASSWD" ];
            }
          ] ++ lib.optionals filesSftpEnabled [
            {
              command = "${sftpKeyListHelper}";
              options = [ "NOPASSWD" ];
            }
          ] ++ lib.optionals freshrssEnabled [
            {
              command = "${freshrssApiPasswordHelper}";
              options = [ "NOPASSWD" ];
            }
          ] ++ lib.optionals kavitaEnabled [
            {
              command = "${kavitaApiKeysHelper}";
              options = [ "NOPASSWD" ];
            }
          ] ++ lib.optionals offlineMediaEnabledForHomepage [
            {
              command = "${showSyncthingDeviceId}";
              options = [ "NOPASSWD" ];
            }
            {
              command = "${offlineMediaStatus}";
              options = [ "NOPASSWD" ];
            }
            {
              command = "${offlineMediaEnroll}";
              options = [ "NOPASSWD" ];
            }
            {
              command = "${offlineMediaRemove}";
              options = [ "NOPASSWD" ];
            }
          ] ++ lib.optionals powerScheduleCfg.available [
            {
              command = "${powerScheduleApply}";
              options = [ "NOPASSWD" ];
            }
          ] ++ [
            {
              command = "${nixBuildModeApply}";
              options = [ "NOPASSWD" ];
            }
          ];
        }
      ];
    }

    (oauth2Proxy.mkSidecarService {
      serviceName = "homepage-oauth2-proxy";
      description = "Dedicated OAuth2 Proxy for the home page";
      clientId = "homepage-web";
      clientSecretFile = config.age.secrets.homepageOauth2ProxyClientSecret.path;
      cookieSecretFile = config.age.secrets.homepageOauth2ProxyCookieSecret.path;
      cookieName = "_oauth2_proxy_homepage";
      domain = host;
      port = vars.networking.ports.oauth2ProxyHomepage;
      upstream = "http://${listenAddress}:${toString listenPort}";
      allowedGroups = homepageAccessGroups;
      codeChallengeMethod = "S256";
      serviceDependencies = [
        "caddy.service"
        "homepage.service"
      ];
      upstreamCheck = {
        displayName = "Homepage";
        url = "http://${listenAddress}:${toString listenPort}/healthz";
      };
    })
  ];
}
