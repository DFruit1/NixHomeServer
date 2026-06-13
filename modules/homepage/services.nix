{ appPackages, config, lib, oauth2Proxy, pkgs, vars, ... }:

let
  serviceUser = "homepage";
  serviceGroup = "homepage";
  listenAddress = vars.networking.loopbackIPv4;
  listenPort = vars.networking.ports.homepage;
  host = "homepage.${vars.domain}";

  photosHost = "photos.${vars.domain}";
  sharePhotosHost = "sharephotos.${vars.domain}";
  filesHost = "files.${vars.domain}";
  paperlessHost = "paperless.${vars.domain}";
  audiobooksHost = "audiobooks.${vars.domain}";
  videosHost = "videos.${vars.domain}";
  booksHost = "books.${vars.domain}";
  wikiHost = "wiki.${vars.domain}";
  passwordsHost = "passwords.${vars.domain}";
  emailsHost = "emails.${vars.domain}";
  downloadsHost = "ytdownload.${vars.domain}";
  backupsHost = vars.kopiaDomain;
  phoneBackupCfg = vars.phoneBackup or { enable = false; };
  phoneBackupSyncthing = phoneBackupCfg.syncthing or { };
  phoneBackupRepositoryPath = phoneBackupCfg.repositoryPath or "${vars.backupRoot}/kopia-phone";
  offlineMusicCfg = vars.offlineMusic or { enable = false; };
  offlineMusicEnabled = offlineMusicCfg.enable or false;
  offlineMusicFolderName = offlineMusicCfg.folderName or "_Music";
  offlineMusicStateDir = offlineMusicCfg.stateDir or "/persist/appdata/offline-music";
  offlineMusicStateFile = "${offlineMusicStateDir}/devices.json";
  offlineMusicFolderIdPrefix = offlineMusicCfg.folderIdPrefix or "nixhomeserver-music";
  syncthingDataDir = "/var/lib/syncthing";
  syncthingConfigDir = "/var/lib/syncthing/.config/syncthing";
  serverLanHost = "${vars.network.hostname}.${vars.networking.dns.lanDomain}";
  kanidmGroups = lib.sort (a: b: a < b) (
    builtins.filter
      (group: !(lib.hasPrefix "idm_" group) && group != "system_admins" && group != "domain_admins")
      (builtins.attrNames (config.services.kanidm.provision.groups or { }))
  );

  caddyHosts = config.services.caddy.virtualHosts;
  hostEnabled = name: builtins.hasAttr name caddyHosts;

  immichEnabled = hostEnabled photosHost;
  paperlessEnabled = hostEnabled paperlessHost;
  audiobookshelfEnabled = hostEnabled audiobooksHost;
  filesEnabled = hostEnabled filesHost;
  jellyfinEnabled = hostEnabled videosHost;
  musicEnabled = offlineMusicEnabled;
  kavitaEnabled = hostEnabled booksHost;
  kiwixEnabled = hostEnabled wikiHost;
  vaultwardenEnabled = hostEnabled passwordsHost;
  mailArchiveEnabled = hostEnabled emailsHost;
  youtubeDownloaderEnabled = hostEnabled downloadsHost;
  kopiaEnabled = hostEnabled backupsHost;
  sftpAuthorizedKeysDir = "/persist/appdata/files-sftp-authorized-keys";
  installSftpKey = pkgs.writeShellScript "homepage-install-sftp-key" ''
    set -euo pipefail

    username="''${1:-}"
    case "$username" in
      ""|*/*|*..*|*[!A-Za-z0-9._-]*)
        echo "invalid username" >&2
        exit 1
        ;;
    esac

    public_key="$(${pkgs.coreutils}/bin/cat | ${pkgs.coreutils}/bin/tr -d '\r' | ${pkgs.gnused}/bin/sed -e 's/[[:space:]]*$//')"
    case "$public_key" in
      "ssh-ed25519 "*|"ssh-rsa "*|"ecdsa-sha2-nistp256 "*|"ecdsa-sha2-nistp384 "*|"ecdsa-sha2-nistp521 "*|"sk-ssh-ed25519@openssh.com "*|"sk-ecdsa-sha2-nistp256@openssh.com "*)
        ;;
      *)
        echo "invalid OpenSSH public key" >&2
        exit 1
        ;;
    esac

    if printf '%s' "$public_key" | ${pkgs.gnugrep}/bin/grep -q '[[:cntrl:]]'; then
      echo "invalid control character in public key" >&2
      exit 1
    fi

    ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root ${lib.escapeShellArg sftpAuthorizedKeysDir}
    tmp="$(${pkgs.coreutils}/bin/mktemp ${lib.escapeShellArg "${sftpAuthorizedKeysDir}/.${serviceUser}.XXXXXX"})"
    trap 'rm -f "$tmp"' EXIT
    ${pkgs.coreutils}/bin/printf '%s\n' "$public_key" > "$tmp"
    ${pkgs.coreutils}/bin/chown root:root "$tmp"
    ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
    target="${sftpAuthorizedKeysDir}/$username"
    ${pkgs.coreutils}/bin/mv "$tmp" "$target"

    saved_key="$(${pkgs.coreutils}/bin/cat "$target")"
    if [ "$saved_key" != "$public_key" ]; then
      echo "saved public key did not match submitted key" >&2
      exit 1
    fi

    owner_group="$(${pkgs.coreutils}/bin/stat -c '%U:%G' "$target")"
    mode="$(${pkgs.coreutils}/bin/stat -c '%a' "$target")"
    if [ "$owner_group" != "root:root" ] || [ "$mode" != "644" ]; then
      echo "saved public key has incorrect ownership or mode: $owner_group $mode" >&2
      exit 1
    fi

    ${pkgs.coreutils}/bin/printf 'installed %s owner=%s mode=%s\n' "$target" "$owner_group" "$mode"
  '';
  showSyncthingDeviceId = pkgs.writeShellScript "homepage-show-syncthing-device-id" ''
    set -euo pipefail

    exec ${pkgs.syncthing}/bin/syncthing \
      --config=${lib.escapeShellArg syncthingConfigDir} \
      --data=${lib.escapeShellArg syncthingDataDir} \
      device-id
  '';
  offlineMusicStatus = pkgs.writeShellScript "homepage-offline-music-status" ''
    set -euo pipefail

    username="''${1:-}"
    case "$username" in
      ""|*/*|*..*|*[!A-Za-z0-9._-]*)
        echo "invalid username" >&2
        exit 1
        ;;
    esac

    state_file=${lib.escapeShellArg offlineMusicStateFile}
    folder_id=${lib.escapeShellArg offlineMusicFolderIdPrefix}-$username
    folder_label="NixHomeServer Music - $username"
    folder_path=${lib.escapeShellArg vars.usersRoot}/"$username"/${lib.escapeShellArg offlineMusicFolderName}

    if [[ -f "$state_file" ]]; then
      user_state="$(${pkgs.jq}/bin/jq --arg username "$username" '.[$username] // {}' "$state_file")"
    else
      user_state="{}"
    fi

    ${pkgs.jq}/bin/jq -n \
      --arg folderId "$folder_id" \
      --arg folderLabel "$folder_label" \
      --arg serverFolderPath "$folder_path" \
      --argjson userState "$user_state" \
      '{
        folderId: $folderId,
        folderLabel: $folderLabel,
        serverFolderPath: $serverFolderPath
      }
      + (if ($userState.deviceId // "") != "" then { enrolledDeviceId: $userState.deviceId } else {} end)
      + (if ($userState.deviceName // "") != "" then { enrolledDeviceName: $userState.deviceName } else {} end)'
  '';
  offlineMusicEnroll = pkgs.writeShellScript "homepage-offline-music-enroll" ''
    set -euo pipefail

    username="''${1:-}"
    case "$username" in
      ""|*/*|*..*|*[!A-Za-z0-9._-]*)
        echo "invalid username" >&2
        exit 1
        ;;
    esac

    payload="$(${pkgs.coreutils}/bin/cat)"
    device_id="$(${pkgs.jq}/bin/jq -er '.deviceId' <<<"$payload")"
    device_name="$(${pkgs.jq}/bin/jq -r --arg fallback "$username-music" '.deviceName // $fallback' <<<"$payload")"

    if ! ${pkgs.gnugrep}/bin/grep -Eq '^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$' <<<"$device_id"; then
      echo "invalid Syncthing device ID" >&2
      exit 1
    fi
    if [[ "''${#device_name}" -lt 1 || "''${#device_name}" -gt 64 ]] \
      || ${pkgs.gnugrep}/bin/grep -q '[[:cntrl:]]' <<<"$device_name" \
      || ! ${pkgs.gnugrep}/bin/grep -Eq '^[A-Za-z0-9._ -]+$' <<<"$device_name"; then
      echo "invalid Syncthing device name" >&2
      exit 1
    fi

    state_dir=${lib.escapeShellArg offlineMusicStateDir}
    state_file=${lib.escapeShellArg offlineMusicStateFile}
    folder_id=${lib.escapeShellArg offlineMusicFolderIdPrefix}-$username
    folder_label="NixHomeServer Music - $username"
    folder_path=${lib.escapeShellArg vars.usersRoot}/"$username"/${lib.escapeShellArg offlineMusicFolderName}

    if [[ ! -d "$folder_path" ]]; then
      ${pkgs.systemd}/bin/systemctl start fileshare-user-root-sync.service
    fi
    if [[ ! -d "$folder_path" ]]; then
      echo "music folder is not provisioned for $username: $folder_path" >&2
      exit 1
    fi

    install -d -m 0750 -o root -g root "$state_dir"
    if [[ ! -f "$state_file" ]]; then
      ${pkgs.coreutils}/bin/printf '{}\n' > "$state_file"
      chmod 0640 "$state_file"
      chown root:root "$state_file"
    fi

    api_key_file="$(${pkgs.coreutils}/bin/mktemp)"
    headers_file="$(${pkgs.coreutils}/bin/mktemp)"
    trap 'rm -f "$api_key_file" "$headers_file"' EXIT
    ${pkgs.libxml2}/bin/xmllint \
      --xpath 'string(configuration/gui/apikey)' \
      ${lib.escapeShellArg syncthingConfigDir}/config.xml \
      >"$api_key_file"
    { ${pkgs.coreutils}/bin/printf 'X-API-Key: '; ${pkgs.coreutils}/bin/cat "$api_key_file"; } >"$headers_file"

    api() {
      local path="$1"
      shift
      ${pkgs.curl}/bin/curl -fsSLk \
        -H "@$headers_file" \
        "$@" \
        "http://127.0.0.1:8384$path"
    }

    api_json() {
      local method="$1"
      local path="$2"
      local json="$3"

      ${pkgs.coreutils}/bin/printf '%s' "$json" | ${pkgs.curl}/bin/curl -fsSLk \
        -X "$method" \
        -H "@$headers_file" \
        -H 'content-type: application/json' \
        --data-binary @- \
        "http://127.0.0.1:8384$path" >/dev/null
    }

    api /rest/system/ping >/dev/null

    old_device_id="$(${pkgs.jq}/bin/jq -r --arg username "$username" '.[$username].deviceId // empty' "$state_file")"

    device_json="$(
      api /rest/config/defaults/device \
        | ${pkgs.jq}/bin/jq \
          --arg deviceId "$device_id" \
          --arg name "$device_name" \
          '.deviceID = $deviceId | .name = $name | .addresses = ["dynamic"]'
    )"
    api_json POST /rest/config/devices "$device_json"

    folder_json="$(
      api /rest/config/defaults/folder \
        | ${pkgs.jq}/bin/jq \
          --arg folderId "$folder_id" \
          --arg label "$folder_label" \
          --arg path "$folder_path" \
          --arg deviceId "$device_id" \
          '.id = $folderId
          | .label = $label
          | .path = $path
          | .type = "sendonly"
          | .devices = [{ deviceID: $deviceId }]
          | .fsWatcherEnabled = true
          | .rescanIntervalS = 3600'
    )"
    api_json POST /rest/config/folders "$folder_json"

    if [[ -n "$old_device_id" && "$old_device_id" != "$device_id" ]]; then
      old_refs="$(api /rest/config/folders | ${pkgs.jq}/bin/jq --arg deviceId "$old_device_id" '[.[].devices[]? | select(.deviceID == $deviceId)] | length')"
      if [[ "$old_refs" == "0" ]]; then
        api /rest/config/devices/"$old_device_id" -X DELETE >/dev/null || true
      fi
    fi

    tmp="$(${pkgs.coreutils}/bin/mktemp "$state_dir/.devices.XXXXXX")"
    ${pkgs.jq}/bin/jq \
      --arg username "$username" \
      --arg deviceId "$device_id" \
      --arg deviceName "$device_name" \
      --arg folderId "$folder_id" \
      --arg updatedAt "$(${pkgs.coreutils}/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.[$username] = {
        deviceId: $deviceId,
        deviceName: $deviceName,
        folderId: $folderId,
        updatedAt: $updatedAt
      }' \
      "$state_file" > "$tmp"
    chmod 0640 "$tmp"
    chown root:root "$tmp"
    mv "$tmp" "$state_file"

    if api /rest/config/restart-required | ${pkgs.jq}/bin/jq -e '.requiresRestart == true' >/dev/null; then
      ${pkgs.systemd}/bin/systemctl restart syncthing.service
    fi

    server_device_id="$(${showSyncthingDeviceId})"
    ${pkgs.jq}/bin/jq -n \
      --arg username "$username" \
      --arg folderId "$folder_id" \
      --arg folderLabel "$folder_label" \
      --arg serverDeviceId "$server_device_id" \
      --arg serverFolderPath "$folder_path" \
      --arg enrolledDeviceId "$device_id" \
      --arg enrolledDeviceName "$device_name" \
      '{
        ok: true,
        username: $username,
        folderId: $folderId,
        folderLabel: $folderLabel,
        serverDeviceId: $serverDeviceId,
        serverFolderPath: $serverFolderPath,
        enrolledDeviceId: $enrolledDeviceId,
        enrolledDeviceName: $enrolledDeviceName
      }'
  '';

  serviceCards = [
    {
      id = "photos";
      name = "Photos";
      url = "https://${photosHost}";
      enabled = immichEnabled;
      category = "media";
      description = "Photo and video library with private login and public share-link support.";
      loginNotes = "Use Kanidm. Public shares use https://${sharePhotosHost}.";
      projectUrl = "https://immich.app";
      logoUrl = "https://cdn.simpleicons.org/immich";
      uploadNotes = "Upload through Immich web or the mobile app.";
    }
    {
      id = "documents";
      name = "Documents";
      url = "https://${paperlessHost}";
      enabled = paperlessEnabled;
      category = "files";
      description = "Paperless document archive with OCR, search, tags, and exports.";
      loginNotes = "Use Kanidm; first login creates the local account.";
      projectUrl = "https://docs.paperless-ngx.com";
      logoUrl = "https://cdn.simpleicons.org/paperlessngx";
      uploadNotes = "Upload PDFs and image documents through Paperless or the consume inbox.";
    }
    {
      id = "files";
      name = "Files";
      url = "https://${filesHost}";
      enabled = filesEnabled;
      category = "files";
      description = "Browser file workspace backed by each user's restricted SFTP root.";
      loginNotes = "Requires user-files for browser access.";
      projectUrl = "https://www.filestash.app";
      logoUrl = "https://raw.githubusercontent.com/mickael-kerjean/filestash/master/public/assets/logo/favicon.svg";
      uploadNotes = "Use Files for general uploads and app-specific media folders.";
    }
    {
      id = "sftp";
      name = "SFTP Access";
      url = "/uploads";
      enabled = filesEnabled;
      category = "files";
      description = "Private SSHFS/SFTP endpoint for large uploads and automated folder sync.";
      loginNotes = "Use uploaded SSHFS public key authentication and port 2222 on ${serverLanHost}.";
      uploadNotes = "Upload your public key once, then mount the server with SSHFS.";
    }
    {
      id = "audiobooks";
      name = "Audiobooks";
      url = "https://${audiobooksHost}/audiobookshelf/";
      enabled = audiobookshelfEnabled;
      category = "media";
      description = "Audiobooks and long-form audio libraries.";
      loginNotes = "Use Kanidm; app-admin grants app admin when combined with access.";
      projectUrl = "https://www.audiobookshelf.org";
      logoUrl = "https://cdn.simpleicons.org/audiobookshelf";
      uploadNotes = "Place audiobook folders under _Audiobooks.";
    }
    {
      id = "videos";
      name = "Videos";
      url = "https://${videosHost}";
      enabled = jellyfinEnabled;
      category = "media";
      description = "Movies, shows, home videos, music videos, and YouTube video libraries.";
      loginNotes = "Jellyfin uses local sign-in; Kanidm groups drive managed account policy.";
      projectUrl = "https://jellyfin.org";
      logoUrl = "https://cdn.simpleicons.org/jellyfin";
      uploadNotes = "Place videos under _Videos with the matching library folder.";
    }
    {
      id = "music";
      name = "Offline Music";
      url = "/services/music";
      enabled = musicEnabled;
      category = "media";
      description = "Personal music folders synced offline to one enrolled device with Syncthing.";
      loginNotes = "Use Kanidm on the homepage, then enroll your Syncthing device ID.";
      projectUrl = "https://syncthing.net";
      logoUrl = "https://cdn.simpleicons.org/syncthing";
      uploadNotes = "Place music files under _Music in your personal files root.";
    }
    {
      id = "books";
      name = "Books";
      url = "https://${booksHost}";
      enabled = kavitaEnabled;
      category = "media";
      description = "Ebooks, comics, and manga in Kavita.";
      loginNotes = "Use Kanidm; first login provisions the local account.";
      projectUrl = "https://www.kavitareader.com";
      logoUrl = "https://raw.githubusercontent.com/Kareadita/Kavita/develop/UI/Web/src/assets/images/logo.svg";
      uploadNotes = "Place books under _Books/_Ebooks, _Comics, or _Manga.";
    }
    {
      id = "wiki";
      name = "Offline Wiki";
      url = "https://${wikiHost}";
      enabled = kiwixEnabled;
      category = "knowledge";
      description = "Kiwix ZIM library for offline reference material.";
      loginNotes = "Use Kanidm with baseline users membership.";
      projectUrl = "https://kiwix.org";
      logoUrl = "https://cdn.simpleicons.org/kiwix";
      uploadNotes = "Operators upload .zim files to the configured Kiwix library root.";
    }
    {
      id = "emails";
      name = "Mail Archive";
      url = "https://${emailsHost}";
      enabled = mailArchiveEnabled;
      category = "knowledge";
      description = "Private mail search, attachment export, and Paperless handoff.";
      loginNotes = "Requires mail-archive-users.";
      uploadNotes = "Synced mail appears as visible .eml mirrors under _Emails.";
    }
    {
      id = "downloads";
      name = "Downloads";
      url = "https://${downloadsHost}";
      enabled = youtubeDownloaderEnabled;
      category = "media";
      description = "Authenticated yt-dlp queue for audio and video downloads.";
      loginNotes = "Requires downloads-users.";
      projectUrl = "https://github.com/yt-dlp/yt-dlp";
      logoUrl = "https://cdn.simpleicons.org/youtube";
      uploadNotes = "Downloads land in personal or shared media folders.";
    }
    {
      id = "passwords";
      name = "Passwords";
      url = "https://${passwordsHost}";
      enabled = vaultwardenEnabled;
      category = "identity";
      description = "Shared password manager for server and account credentials.";
      loginNotes = "Vaultwarden is self-service: open the signup page on first visit and register with your local account email.";
      projectUrl = "https://github.com/dani-garcia/vaultwarden";
      logoUrl = "https://cdn.simpleicons.org/vaultwarden";
      uploadNotes = "Store Kanidm credentials, recovery codes, and app-local passwords here.";
    }
    {
      id = "backups";
      name = "Backups";
      url = "https://${backupsHost}";
      enabled = kopiaEnabled;
      category = "operations";
      description = "Kopia backup management for system state and repositories.";
      loginNotes = "Requires backup-admins plus the native Kopia password.";
      projectUrl = "https://kopia.io";
      logoUrl = "https://raw.githubusercontent.com/kopia/kopia/master/icons/kopia.svg";
      uploadNotes = "Backup repository files are managed by Kopia.";
    }
  ];

  folderGuides = [
    {
      id = "documents";
      title = "Documents";
      enabled = paperlessEnabled;
      serviceIds = [ "documents" "files" "emails" ];
      fileTypes = [ "pdf" "jpg" "jpeg" "png" "tiff" "eml attachments" ];
      personalPath = "/mnt/data/users/{username}/_Files";
      sharedPath = "${vars.dataRoot}/paperless/inbox";
      instructions = [
        "Use Paperless for scanned documents, bills, statements, receipts, and searchable PDFs."
        "Prefer PDF or image files. Convert office documents before handing them to Paperless."
        "Use Mail Archive attachment handoff when an email attachment should become a Paperless document."
      ];
    }
    {
      id = "photos";
      title = "Photos And Phone Media";
      enabled = immichEnabled;
      serviceIds = [ "photos" ];
      fileTypes = [ "jpg" "jpeg" "png" "heic" "webp" "mov" "mp4" ];
      personalPath = null;
      sharedPath = "${vars.dataRoot}/immich/external";
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
      personalPath = "/mnt/data/users/{username}/_Audiobooks";
      sharedPath = "${vars.sharedRoot}/_Audiobooks";
      instructions = [
        "Keep each audiobook in its own folder with cover art and metadata beside the audio files."
        "Use _Audiobooks/_YouTube for audio produced by the downloader."
        "Pure audio with thumbnails belongs in Audiobookshelf, not Jellyfin."
      ];
    }
    {
      id = "videos";
      title = "Videos";
      enabled = jellyfinEnabled;
      serviceIds = [ "videos" "downloads" "files" ];
      fileTypes = [ "mkv" "mp4" "webm" "avi" "srt" "ass" "nfo" ];
      personalPath = "/mnt/data/users/{username}/_Videos";
      sharedPath = "${vars.sharedRoot}/_Videos";
      instructions = [
        "Put films in _Movies, series in _Shows, personal clips in _Home, music videos in _Music-videos, and downloaded videos in _YouTube."
        "Keep show seasons grouped clearly so Jellyfin can identify them."
        "Subtitle and metadata files should live beside the matching video file."
      ];
    }
    {
      id = "music";
      title = "Offline Music";
      enabled = musicEnabled;
      serviceIds = [ "music" "files" ];
      fileTypes = [ "mp3" "flac" "m4a" "opus" "ogg" "wav" ];
      personalPath = "/mnt/data/users/{username}/${offlineMusicFolderName}";
      sharedPath = "${vars.sharedRoot}/${offlineMusicFolderName}";
      instructions = [
        "Place music files in your personal _Music folder."
        "Enroll your phone or music device from the Offline Music service page."
        "The server publishes music as send-only; device-side deletes do not remove the server copy."
      ];
    }
    {
      id = "books";
      title = "Books, Comics, Manga";
      enabled = kavitaEnabled;
      serviceIds = [ "books" "files" ];
      fileTypes = [ "epub" "pdf" "cbz" "cbr" "zip" "rar" ];
      personalPath = "/mnt/data/users/{username}/_Books";
      sharedPath = "${vars.sharedRoot}/_Books";
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
      personalPath = "/mnt/data/users/{username}/_Emails";
      sharedPath = "${vars.sharedRoot}/_Emails";
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
      sharedPath = "${vars.dataRoot}/kiwix";
      instructions = [
        "Use complete .zim files only."
        "Kiwix library uploads are operator-managed because the server regenerates its library catalog."
        "After upload, the Kiwix sync service publishes valid ZIM files into the web library."
      ];
    }
  ];

  adminGuide = [
    {
      title = "Configure the host";
      command = "$EDITOR vars.nix";
      detail = "Set identity, network, DNS, storage, and access groups before bootstrap or deploy.";
    }
    {
      title = "Manage Kanidm entity removal explicitly";
      command = "$EDITOR modules/Core_Modules/kanidm/provision.nix";
      detail = "Kanidm is configured with autoremove disabled, so deleted module groups/users are kept for rescue/reprovisioning safety. Clean up stale groups/users intentionally (for example using `present = false` in provision entries) before retiring a module or host.";
    }
    {
      title = "Validate settings";
      command = "nix run .#validate-config-readiness && nix run .#show-config-summary";
      detail = "Evaluate the flake and preview hostnames, OAuth clients, groups, storage, and required secrets.";
    }
    {
      title = "Generate secrets";
      command = "./scripts/generate-all-secrets.sh";
      detail = "Generate repo-managed secrets and encrypt staged external secrets under secrets/.";
    }
    {
      title = "Blank-machine install";
      command = "nixos-install --flake /mnt/etc/nixos#server";
      detail = "Use documentation/quickstart.md only for installer-time disk, agenix key, and first install work.";
    }
    {
      title = "Guarded deploy";
      command = "./scripts/deploy.sh --action test";
      detail = "Stage the repo archive and run the normal remote rebuild test path on the server.";
    }
    {
      title = "Switch after test";
      command = "./scripts/deploy.sh --action switch";
      detail = "Switch only after the guarded test path passes and failed systemd units are clear.";
    }
  ];

  homepageConfig = pkgs.writeText "homepage-config.json" (builtins.toJSON {
    domain = vars.domain;
    serverLanHost = serverLanHost;
    sshfsHost = vars.network.hostname;
    services = serviceCards;
    kanidmGroups = kanidmGroups;
    phoneBackup = {
      enabled = phoneBackupCfg.enable or false;
      deviceName = phoneBackupSyncthing.deviceName or "phone";
      configuredPhoneDeviceId = phoneBackupSyncthing.deviceId or "";
      folderId = phoneBackupSyncthing.folderId or "nixhomeserver-kopia-phone";
      folderLabel = "NixHomeServer Kopia phone backup";
      repositoryPath = phoneBackupRepositoryPath;
      connectionAddresses = [
        "tcp://${serverLanHost}:22000"
        "tcp://${vars.networking.lan.ip}:22000"
        "tcp://${vars.networking.netbird.ip}:22000"
      ];
    };
    offlineMusic = {
      enabled = offlineMusicEnabled;
      folderName = offlineMusicFolderName;
      folderIdPrefix = offlineMusicFolderIdPrefix;
      connectionAddresses = [
        "tcp://${serverLanHost}:22000"
        "tcp://${vars.networking.lan.ip}:22000"
        "tcp://${vars.networking.netbird.ip}:22000"
      ];
    };
    inherit folderGuides adminGuide;
  });
in
{
  config = lib.mkMerge [
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
        ];
        after = [
          "network-online.target"
        ];
        environment = {
          HOMEPAGE_HOST = listenAddress;
          HOMEPAGE_PORT = toString listenPort;
          HOMEPAGE_CONFIG_FILE = homepageConfig;
          HOMEPAGE_SFTP_KEY_INSTALL_COMMAND = installSftpKey;
          HOMEPAGE_SYNCTHING_DEVICE_ID_COMMAND = showSyncthingDeviceId;
          HOMEPAGE_OFFLINE_MUSIC_STATUS_COMMAND = offlineMusicStatus;
          HOMEPAGE_OFFLINE_MUSIC_ENROLL_COMMAND = offlineMusicEnroll;
          HOMEPAGE_SUDO = "/run/wrappers/bin/sudo";
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
          ReadWritePaths = [
            sftpAuthorizedKeysDir
          ];
          ReadOnlyPaths = [
            homepageConfig
          ];
        };
      };

      systemd.tmpfiles.rules = [
        "d ${sftpAuthorizedKeysDir} 0755 root root -"
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
              command = "${showSyncthingDeviceId}";
              options = [ "NOPASSWD" ];
            }
            {
              command = "${offlineMusicStatus}";
              options = [ "NOPASSWD" ];
            }
            {
              command = "${offlineMusicEnroll}";
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
      allowedGroups = [ "users" ];
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
