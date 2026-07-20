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
  requestsHost = "requests.${vars.domain}";
  sonarrHost = "sonarr.${vars.domain}";
  radarrHost = "radarr.${vars.domain}";
  prowlarrHost = "prowlarr.${vars.domain}";
  torrentsHost = "torrents.${vars.domain}";
  backupsHost = vars.kopiaDomain;
  monitorHost = vars.monitorDomain;
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
      "Requires baseline users membership; connect each computer or phone once, then Syncthing keeps its offline copies up to date."
    else
      "Requires baseline users membership plus ${offlineMediaAccessGroup}; connect each computer or phone once, then Syncthing keeps its offline copies up to date.";
  filesWebAccessGroup = vars.fileAccess.webAccessGroup or "files-personal-users";
  filesSftpAccessGroup = vars.fileAccess.sftpAccessGroup or "files-sftp-users";
  filesSharedAccessGroup = vars.fileAccess.sharedAccessGroup or "files-shared-users";
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
  offlineMediaStateDir = offlineMediaCfg.stateDir or "/persist/appdata/offline-media";
  offlineMediaStateFile = "${offlineMediaStateDir}/devices.json";
  offlineMediaModel = (import ../../lib/offline-media.nix { inherit lib; }) offlineMediaCfg;
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
    (name: group:
      if !(group.overwriteMembers or true) then
        "manual"
      else if name == vars.backupAdminGroup then
        "backupAccess.adminUsers"
      else if name == vars.backupStorageGroup then
        "backupAccess.storageUsers"
      else
        "identity.appUsers")
    (config.services.kanidm.provision.groups or { });

  caddyHosts = config.services.caddy.virtualHosts;
  hostEnabled = name: builtins.hasAttr name caddyHosts;

  immichEnabled = hostEnabled photosHost;
  paperlessEnabled = hostEnabled paperlessHost;
  audiobookshelfEnabled = hostEnabled audiobooksHost;
  filesEnabled = hostEnabled filesHost;
  filesSftpEnabled = builtins.hasAttr "files-sftp-sshd" config.systemd.services;
  jellyfinEnabled = hostEnabled videosHost;
  offlineMediaEnabledForHomepage = offlineMediaEnabled;
  kavitaEnabled = hostEnabled booksHost;
  kiwixEnabled = hostEnabled wikiHost;
  vaultwardenEnabled = hostEnabled passwordsHost;
  mailArchiveEnabled = hostEnabled emailsHost;
  youtubeDownloaderEnabled = hostEnabled downloadsHost;
  seerrEnabled = hostEnabled requestsHost;
  sonarrEnabled = hostEnabled sonarrHost;
  radarrEnabled = hostEnabled radarrHost;
  prowlarrEnabled = hostEnabled prowlarrHost;
  qbittorrentEnabled = hostEnabled torrentsHost;
  kopiaEnabled = hostEnabled backupsHost;
  monitorEnabled = hostEnabled monitorHost;
  personalPath = relativePath: "/${relativePath}";
  sharedPath = relativePath: "/${vars.fileAccess.sharedMountName}/${relativePath}";
  sftpAuthorizedKeysDir = "/persist/appdata/files-sftp-authorized-keys";
  installSftpKey = pkgs.writeShellScript "homepage-install-sftp-key" ''
    set -euo pipefail

    username="''${1:-}"
    if ! ${pkgs.gnugrep}/bin/grep -Eq '^[a-z][a-z0-9._-]{0,63}$' <<<"$username"; then
      echo "invalid username" >&2
      exit 1
    fi

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

    key_check="$(${pkgs.coreutils}/bin/mktemp)"
    trap '${pkgs.coreutils}/bin/rm -f "$key_check"' EXIT
    ${pkgs.coreutils}/bin/printf '%s\n' "$public_key" > "$key_check"
    if ! ${pkgs.openssh}/bin/ssh-keygen -l -f "$key_check" >/dev/null 2>&1; then
      echo "invalid or corrupted OpenSSH public key" >&2
      exit 1
    fi
    ${pkgs.coreutils}/bin/rm -f "$key_check"
    trap - EXIT

    ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root ${lib.escapeShellArg sftpAuthorizedKeysDir}
    exec 9>"${sftpAuthorizedKeysDir}/.$username.lock"
    ${pkgs.util-linux}/bin/flock -x 9
    target="${sftpAuthorizedKeysDir}/$username"
    if [[ -L "$target" ]]; then
      echo "refusing symlinked authorized-keys file" >&2
      exit 1
    fi
    tmp="$(${pkgs.coreutils}/bin/mktemp ${lib.escapeShellArg "${sftpAuthorizedKeysDir}/.${serviceUser}.XXXXXX"})"
    trap 'rm -f "$tmp"' EXIT
    if [[ -e "$target" ]]; then
      owner_group="$(${pkgs.coreutils}/bin/stat -c '%U:%G' "$target")"
      mode="$(${pkgs.coreutils}/bin/stat -c '%a' "$target")"
      if [[ "$owner_group" != "root:root" || "$mode" != "644" || ! -f "$target" ]]; then
        echo "existing authorized-keys file has unsafe ownership, mode, or type" >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/cat "$target" > "$tmp"
    fi
    if ! ${pkgs.gnugrep}/bin/grep -Fqx -- "$public_key" "$tmp"; then
      key_count="$(${pkgs.gnugrep}/bin/grep -cve '^[[:space:]]*$' "$tmp" || true)"
      if (( key_count >= 10 )); then
        echo "at most 10 SFTP device keys may be registered; ask an administrator to retire an old key" >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/printf '%s\n' "$public_key" >> "$tmp"
    fi
    ${pkgs.coreutils}/bin/chown root:root "$tmp"
    ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
    ${pkgs.coreutils}/bin/mv "$tmp" "$target"

    if ! ${pkgs.gnugrep}/bin/grep -Fqx -- "$public_key" "$target"; then
      echo "saved authorized-keys file does not contain submitted key" >&2
      exit 1
    fi

    owner_group="$(${pkgs.coreutils}/bin/stat -c '%U:%G' "$target")"
    mode="$(${pkgs.coreutils}/bin/stat -c '%a' "$target")"
    if [ "$owner_group" != "root:root" ] || [ "$mode" != "644" ]; then
      echo "saved public key has incorrect ownership or mode: $owner_group $mode" >&2
      exit 1
    fi

    key_count="$(${pkgs.gnugrep}/bin/grep -cve '^[[:space:]]*$' "$target")"
    ${pkgs.coreutils}/bin/printf 'saved %s owner=%s mode=%s registered-keys=%s\n' "$target" "$owner_group" "$mode" "$key_count"
  '';
  showSyncthingDeviceId = pkgs.writeShellScript "homepage-show-syncthing-device-id" ''
    set -euo pipefail

    exec ${pkgs.syncthing}/bin/syncthing \
      --config=${lib.escapeShellArg syncthingConfigDir} \
      --data=${lib.escapeShellArg syncthingDataDir} \
      device-id
  '';
  offlineMediaStatus = pkgs.writeShellScript "homepage-offline-media-status" ''
    set -euo pipefail

    username="''${1:-}"
    if ! ${pkgs.gnugrep}/bin/grep -Eq '^[a-z][a-z0-9._-]{0,63}$' <<<"$username"; then
      echo "invalid username" >&2
      exit 1
    fi

    state_file=${lib.escapeShellArg offlineMediaStateFile}
    folder_specs_json=${lib.escapeShellArg offlineMediaFolderSpecsJson}
    users_root=${lib.escapeShellArg vars.usersRoot}
    runtime_error=""
    runtime_devices='[]'

    if [[ -f "$state_file" ]]; then
      state="$(${pkgs.jq}/bin/jq -c '
        if .version == 2 then .
        else {
          version: 2,
          users: (
            to_entries
            | map(select((.value.deviceId // "") != ""))
            | map({
              key: .key,
              value: {
                devices: [{
                  deviceId: .value.deviceId,
                  deviceName: (.value.deviceName // (.key + "-media")),
                  createdAt: (.value.updatedAt // ""),
                  updatedAt: (.value.updatedAt // "")
                }]
              }
            })
            | from_entries
          )
        }
        end' "$state_file")"
    else
      state='{"version":2,"users":{}}'
    fi
    if ! ${pkgs.jq}/bin/jq -e '${offlineMediaStateValidationJq}' <<<"$state" >/dev/null; then
      echo "offline media enrollment state is invalid" >&2
      exit 1
    fi

    api_key_file="$(${pkgs.coreutils}/bin/mktemp)"
    headers_file="$(${pkgs.coreutils}/bin/mktemp)"
    trap 'rm -f "$api_key_file" "$headers_file"' EXIT
    if ! ${pkgs.libxml2}/bin/xmllint \
      --xpath 'string(configuration/gui/apikey)' \
      ${lib.escapeShellArg syncthingConfigDir}/config.xml \
      >"$api_key_file" 2>/dev/null \
      || [[ ! -s "$api_key_file" ]]; then
      runtime_error="Syncthing configuration is unavailable"
    else
      { ${pkgs.coreutils}/bin/printf 'X-API-Key: '; ${pkgs.coreutils}/bin/cat "$api_key_file"; } >"$headers_file"

      api() {
        local path="$1"
        ${pkgs.curl}/bin/curl -fsSL \
          --connect-timeout 1 \
          --max-time 3 \
          -H "@$headers_file" \
          "http://127.0.0.1:8384$path"
      }

      if api /rest/system/ping >/dev/null 2>&1; then
        if connections="$(api /rest/system/connections 2>/dev/null)" \
          && device_stats="$(api /rest/stats/device 2>/dev/null)"; then
          while IFS=$'\t' read -r enrolled_device_id; do
            [[ -n "$enrolled_device_id" ]] || continue
            completion_rows='[]'
            sync_error=""
            while IFS=$'\t' read -r folder_id_prefix; do
              folder_id="$folder_id_prefix-$username"
              if completion="$(api "/rest/db/completion?device=$enrolled_device_id&folder=$folder_id" 2>/dev/null)"; then
                completion_rows="$(${pkgs.jq}/bin/jq \
                  --argjson completion "$completion" \
                  '. + [$completion]' \
                  <<<"$completion_rows")"
              else
                sync_error="One or more folder statuses could not be read"
              fi
            done < <(${pkgs.jq}/bin/jq -r '.[] | [.folderIdPrefix] | @tsv' <<<"$folder_specs_json")

            runtime_device="$(${pkgs.jq}/bin/jq -n \
              --arg deviceId "$enrolled_device_id" \
              --arg syncError "$sync_error" \
              --argjson connections "$connections" \
              --argjson stats "$device_stats" \
              --argjson rows "$completion_rows" \
              '{
                deviceId: $deviceId,
                connected: ($connections.connections[$deviceId].connected // false),
                lastSeen: ($stats[$deviceId].lastSeen // null),
                needBytes: ([$rows[]?.needBytes // 0] | add // 0),
                needItems: ([$rows[]?.needItems // 0] | add // 0),
                completion: (
                  ([$rows[]?.globalBytes // 0] | add // 0) as $total
                  | ([$rows[]?.needBytes // 0] | add // 0) as $needed
                  | if $total > 0 then ((($total - $needed) * 10000 / $total) | floor / 100) else 100 end
                ),
                syncError: (if $syncError == "" then null else $syncError end)
              }')"
            runtime_devices="$(${pkgs.jq}/bin/jq \
              --argjson device "$runtime_device" \
              '. + [$device]' \
              <<<"$runtime_devices")"
          done < <(${pkgs.jq}/bin/jq -r --arg username "$username" '.users[$username].devices[]?.deviceId' <<<"$state")
        else
          runtime_error="Syncthing status is temporarily unavailable"
        fi
      else
        runtime_error="Syncthing is not responding"
      fi
    fi

    ${pkgs.jq}/bin/jq -n \
      --arg username "$username" \
      --arg usersRoot "$users_root" \
      --arg runtimeError "$runtime_error" \
      --argjson specs "$folder_specs_json" \
      --argjson state "$state" \
      --argjson runtimeDevices "$runtime_devices" \
      '{
        folders: [
          $specs[] | {
            key,
            label,
            folderId: (.folderIdPrefix + "-" + $username),
            folderLabel: ("NixHomeServer " + .label + " - " + $username),
            serverFolderPath: ($usersRoot + "/" + $username + "/" + .relativePath),
            suggestedDevicePath
          }
        ],
        devices: (
          ($state.users[$username].devices // [])
          | map(
              . as $saved
              | . + (
                  first($runtimeDevices[]? | select(.deviceId == $saved.deviceId))
                  // (if $runtimeError == "" then {} else {syncError: $runtimeError} end)
                )
            )
        ),
        runtimeError: (if $runtimeError == "" then null else $runtimeError end)
      }'
  '';
  offlineMediaEnroll = pkgs.writeShellScript "homepage-offline-media-enroll" ''
    set -euo pipefail

    username="''${1:-}"
    if ! ${pkgs.gnugrep}/bin/grep -Eq '^[a-z][a-z0-9._-]{0,63}$' <<<"$username"; then
      echo "invalid username" >&2
      exit 1
    fi

    payload="$(${pkgs.coreutils}/bin/cat)"
    device_id="$(${pkgs.jq}/bin/jq -er '.deviceId' <<<"$payload")"
    device_name="$(${pkgs.jq}/bin/jq -er --arg fallback "$username-media" '
      if .deviceName == null then $fallback
      elif (.deviceName | type) == "string" then .deviceName
      else error("deviceName must be a string")
      end
    ' <<<"$payload")"

    if ! ${pkgs.gnugrep}/bin/grep -Eq '^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$' <<<"$device_id"; then
      echo "invalid Syncthing device ID" >&2
      exit 1
    fi
    if ! ${pkgs.jq}/bin/jq -en --arg deviceName "$device_name" \
      '$deviceName | test("^[A-Za-z0-9._ -]{1,64}$")' >/dev/null; then
      echo "invalid Syncthing device name" >&2
      exit 1
    fi

    server_device_id="$(${showSyncthingDeviceId})"
    if [[ "$device_id" == "$server_device_id" ]]; then
      echo "paste this device's Syncthing device ID, not the server device ID" >&2
      exit 1
    fi

    state_dir=${lib.escapeShellArg offlineMediaStateDir}
    state_file=${lib.escapeShellArg offlineMediaStateFile}
    folder_specs_json=${lib.escapeShellArg offlineMediaFolderSpecsJson}
    users_root=${lib.escapeShellArg vars.usersRoot}

    install -d -m 0750 -o root -g root "$state_dir"
    exec 9>"$state_dir/.devices.lock"
    ${pkgs.util-linux}/bin/flock -x 9

    # The browser token can outlive a group change.  Verify current Kanidm
    # membership under the same lock before creating folders, ACLs, peers, or
    # enrollment state.  Offline-media access is always additive to users.
    identity_home="$(${pkgs.coreutils}/bin/mktemp -d)"
    trap '${pkgs.coreutils}/bin/rm -rf "$identity_home"' EXIT
    export HOME="$identity_home"
    KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmAdminPass.path})"
    export KANIDM_PASSWORD
    ${pkgs.kanidm_1_10}/bin/kanidm login \
      -H ${lib.escapeShellArg "https://${vars.kanidmDomain}:${toString vars.networking.ports.kanidm}"} \
      -D idm_admin >/dev/null

    snapshot_enrollment_group() {
      local group_name="$1"
      local group_json
      if ! group_json="$(${pkgs.kanidm_1_10}/bin/kanidm group get \
        "$group_name" \
        -H ${lib.escapeShellArg "https://${vars.kanidmDomain}:${toString vars.networking.ports.kanidm}"} \
        -D idm_admin \
        -o json)"; then
        echo "unable to verify current offline-media membership; no device was enrolled" >&2
        return 1
      fi
      ${pkgs.jq}/bin/jq -cer '
        def local_username:
          split("@")[0] as $username
          | if ($username | test("^[a-z][a-z0-9._-]{0,63}$")) then
              $username
            else
              error("invalid local username in member entry")
            end;
        if ((.attrs.member // []) | type) != "array" then
          error("invalid member attribute")
        elif any(.attrs.member[]?; type != "string") then
          error("member array contains a non-string entry")
        else
          [ .attrs.member[]? | local_username ] | unique
        end
      ' <<<"$group_json"
    }

    if ! baseline_members="$(${pkgs.jq}/bin/jq -c . <<<"$(snapshot_enrollment_group users)")"; then
      exit 1
    fi
    if [[ ${lib.escapeShellArg offlineMediaAccessGroup} == users ]]; then
      access_members="$baseline_members"
    elif ! access_members="$(${pkgs.jq}/bin/jq -c . <<<"$(snapshot_enrollment_group ${lib.escapeShellArg offlineMediaAccessGroup})")"; then
      exit 1
    fi
    if ! ${pkgs.jq}/bin/jq -en \
      --arg username "$username" \
      --argjson baseline "$baseline_members" \
      --argjson access "$access_members" \
      '($baseline | index($username) != null) and ($access | index($username) != null)' >/dev/null; then
      echo "current Kanidm membership no longer permits offline-media enrollment" >&2
      exit 1
    fi
    ${pkgs.coreutils}/bin/rm -rf "$identity_home"
    trap - EXIT

    # Validate persistent enrollment state before provisioning folders or
    # changing ACLs.  First-host initialization is an atomic replacement, so
    # interruption cannot leave a truncated devices.json behind.
    if [[ ! -f "$state_file" ]]; then
      state_init_tmp="$(${pkgs.coreutils}/bin/mktemp "$state_dir/.devices.XXXXXX")"
      if ! ${pkgs.coreutils}/bin/printf '{"version":2,"users":{}}\n' > "$state_init_tmp" \
        || ! ${pkgs.jq}/bin/jq -e '${offlineMediaStateValidationJq}' "$state_init_tmp" >/dev/null \
        || ! ${pkgs.coreutils}/bin/chmod 0640 "$state_init_tmp" \
        || ! ${pkgs.coreutils}/bin/chown root:root "$state_init_tmp" \
        || ! ${pkgs.coreutils}/bin/mv "$state_init_tmp" "$state_file"; then
        ${pkgs.coreutils}/bin/rm -f "$state_init_tmp"
        echo "unable to initialize offline media enrollment state" >&2
        exit 1
      fi
    fi
    if ! ${pkgs.jq}/bin/jq -e '${offlineMediaStateValidationJq}' "$state_file" >/dev/null; then
      echo "offline media enrollment state is invalid; refusing to provision folders or change ACLs" >&2
      exit 1
    fi

    missing_folder=0
    while IFS=$'\t' read -r relative_path; do
      folder_path="$users_root/$username/$relative_path"
      [[ -d "$folder_path" ]] || missing_folder=1
    done < <(${pkgs.jq}/bin/jq -r '.[] | [.relativePath] | @tsv' <<<"$folder_specs_json")
    if (( missing_folder == 1 )); then
      ${pkgs.systemd}/bin/systemctl start fileshare-user-root-sync.service
    fi
    while IFS=$'\t' read -r relative_path; do
      folder_path="$users_root/$username/$relative_path"
      if [[ ! -d "$folder_path" ]]; then
        echo "offline media folder is not provisioned for $username: $folder_path" >&2
        exit 1
      fi
    done < <(${pkgs.jq}/bin/jq -r '.[] | [.relativePath] | @tsv' <<<"$folder_specs_json")

    grant_syncthing_read() {
      local folder_path="$1"
      local parent_path="$folder_path"

      while [[ "$parent_path" != "$users_root/$username" && "$parent_path" != "/" ]]; do
        parent_path="$(${pkgs.coreutils}/bin/dirname "$parent_path")"
        ${pkgs.acl}/bin/setfacl -m g:syncthing:--x "$parent_path"
      done

      ${pkgs.acl}/bin/setfacl -R -m g:syncthing:r-X "$folder_path"
      ${pkgs.findutils}/bin/find "$folder_path" -type d -exec ${pkgs.acl}/bin/setfacl -m d:g:syncthing:r-x '{}' +
      install -d -m 0755 -o root -g root "$folder_path/.stfolder"
      ${pkgs.acl}/bin/setfacl -m g:syncthing:r-x "$folder_path/.stfolder"
    }

    while IFS=$'\t' read -r relative_path; do
      grant_syncthing_read "$users_root/$username/$relative_path"
    done < <(${pkgs.jq}/bin/jq -r '.[] | [.relativePath] | @tsv' <<<"$folder_specs_json")

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

    devices_json="$(api /rest/config/devices)"
    default_device_json="$(api /rest/config/defaults/device)"
    device_json="$(
      ${pkgs.jq}/bin/jq -n \
        --arg deviceId "$device_id" \
        --arg name "$device_name" \
        --argjson devices "$devices_json" \
        --argjson defaultDevice "$default_device_json" \
        '(
          ($devices[]? | select(.deviceID == $deviceId)) // $defaultDevice
        )
        | .deviceID = $deviceId
        | .name = $name
        | .addresses = ((.addresses // []) | if length > 0 then . else ["dynamic"] end)'
    )"

    # Commit the validated enrollment intent before the first Syncthing
    # mutation.  If a later API call fails, the reconciler can safely finish
    # converging this durable intent and a user retry remains idempotent.
    state_tmp="$(${pkgs.coreutils}/bin/mktemp "$state_dir/.devices.XXXXXX")"
    ${pkgs.jq}/bin/jq \
      --arg username "$username" \
      --arg deviceId "$device_id" \
      --arg deviceName "$device_name" \
      --arg updatedAt "$(${pkgs.coreutils}/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '
      def v2:
        if .version == 2 then .
        else {
          version: 2,
          users: (
            to_entries
            | map(select((.value.deviceId // "") != ""))
            | map({
              key: .key,
              value: {
                devices: [{
                  deviceId: .value.deviceId,
                  deviceName: (.value.deviceName // (.key + "-media")),
                  createdAt: (.value.updatedAt // $updatedAt),
                  updatedAt: (.value.updatedAt // $updatedAt)
                }]
              }
            })
            | from_entries
          )
        }
        end;
      v2
      | .version = 2
      | .users[$username].devices = (
          ((.users[$username].devices // []) | map(select(.deviceId != $deviceId)))
          + [{
            deviceId: $deviceId,
            deviceName: $deviceName,
            createdAt: (((.users[$username].devices // [])[]? | select(.deviceId == $deviceId) | .createdAt) // $updatedAt),
            updatedAt: $updatedAt
          }]
        )
      ' \
      "$state_file" > "$state_tmp"
    if ! ${pkgs.jq}/bin/jq -e '${offlineMediaStateValidationJq}' "$state_tmp" >/dev/null; then
      ${pkgs.coreutils}/bin/rm -f "$state_tmp"
      echo "refusing to save invalid offline media enrollment state" >&2
      exit 1
    fi
    chmod 0640 "$state_tmp"
    chown root:root "$state_tmp"
    mv "$state_tmp" "$state_file"

    api_json POST /rest/config/devices "$device_json"

    while IFS=$'\t' read -r key label relative_path folder_id_prefix suggested_device_path; do
      folder_id="$folder_id_prefix-$username"
      folder_label="NixHomeServer $label - $username"
      folder_path="$users_root/$username/$relative_path"
      folders_json="$(api /rest/config/folders)"
      default_folder_json="$(api /rest/config/defaults/folder)"
      folder_json="$(
        ${pkgs.jq}/bin/jq -n \
          --arg folderId "$folder_id" \
          --arg label "$folder_label" \
          --arg path "$folder_path" \
          --arg deviceId "$device_id" \
          --argjson folders "$folders_json" \
          --argjson defaultFolder "$default_folder_json" \
          '(
            ($folders[]? | select(.id == $folderId)) // $defaultFolder
          )
          | .id = $folderId
          | .label = $label
          | .path = $path
          | .type = "sendonly"
          | .devices = ((((.devices // []) | map(.deviceID)) + [$deviceId]) | unique | map({ deviceID: . }))
          | .fsWatcherEnabled = true
          | .rescanIntervalS = 300'
      )"
      api_json POST /rest/config/folders "$folder_json"
    done < <(${pkgs.jq}/bin/jq -r '.[] | [.key, .label, .relativePath, .folderIdPrefix, .suggestedDevicePath] | @tsv' <<<"$folder_specs_json")

    if api /rest/config/restart-required | ${pkgs.jq}/bin/jq -e '.requiresRestart == true' >/dev/null; then
      ${pkgs.systemd}/bin/systemctl restart syncthing.service
    fi

    status_json="$(${offlineMediaStatus} "$username")"
    ${pkgs.jq}/bin/jq -n \
      --arg username "$username" \
      --arg serverDeviceId "$server_device_id" \
      --arg enrolledDeviceId "$device_id" \
      --arg enrolledDeviceName "$device_name" \
      --argjson status "$status_json" \
      '{
        ok: true,
        username: $username,
        serverDeviceId: $serverDeviceId,
        enrolledDeviceId: $enrolledDeviceId,
        enrolledDeviceName: $enrolledDeviceName,
        folders: $status.folders,
        devices: $status.devices
      }'
  '';
  offlineMediaRemove = pkgs.writeShellScript "homepage-offline-media-remove" ''
    set -euo pipefail

    username="''${1:-}"
    device_id="''${2:-}"
    if ! ${pkgs.gnugrep}/bin/grep -Eq '^[a-z][a-z0-9._-]{0,63}$' <<<"$username"; then
      echo "invalid username" >&2
      exit 1
    fi
    if ! ${pkgs.gnugrep}/bin/grep -Eq '^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$' <<<"$device_id"; then
      echo "invalid Syncthing device ID" >&2
      exit 1
    fi

    state_dir=${lib.escapeShellArg offlineMediaStateDir}
    state_file=${lib.escapeShellArg offlineMediaStateFile}
    folder_specs_json=${lib.escapeShellArg offlineMediaFolderSpecsJson}

    install -d -m 0750 -o root -g root "$state_dir"
    exec 9>"$state_dir/.devices.lock"
    ${pkgs.util-linux}/bin/flock -x 9
    if [[ ! -f "$state_file" ]]; then
      state_init_tmp="$(${pkgs.coreutils}/bin/mktemp "$state_dir/.devices.XXXXXX")"
      if ! ${pkgs.coreutils}/bin/printf '{"version":2,"users":{}}\n' > "$state_init_tmp" \
        || ! ${pkgs.jq}/bin/jq -e '${offlineMediaStateValidationJq}' "$state_init_tmp" >/dev/null \
        || ! ${pkgs.coreutils}/bin/chmod 0640 "$state_init_tmp" \
        || ! ${pkgs.coreutils}/bin/chown root:root "$state_init_tmp" \
        || ! ${pkgs.coreutils}/bin/mv "$state_init_tmp" "$state_file"; then
        ${pkgs.coreutils}/bin/rm -f "$state_init_tmp"
        echo "unable to initialize offline media enrollment state" >&2
        exit 1
      fi
    fi
    if ! ${pkgs.jq}/bin/jq -e '${offlineMediaStateValidationJq}' "$state_file" >/dev/null; then
      echo "offline media enrollment state is invalid; refusing to change Syncthing" >&2
      exit 1
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

    while IFS=$'\t' read -r folder_id_prefix; do
      folder_id="$folder_id_prefix-$username"
      folders_json="$(api /rest/config/folders)"
      if ! ${pkgs.jq}/bin/jq -e --arg folderId "$folder_id" 'any(.[]; .id == $folderId)' >/dev/null <<<"$folders_json"; then
        continue
      fi
      if ! ${pkgs.jq}/bin/jq -e --arg folderId "$folder_id" --arg deviceId "$device_id" \
          'any(.[] | select(.id == $folderId) | (.devices // [])[]?; .deviceID == $deviceId)' \
          <<<"$folders_json" >/dev/null; then
        continue
      fi
      folder_json="$(
        ${pkgs.jq}/bin/jq \
          --arg folderId "$folder_id" \
          --arg deviceId "$device_id" \
          '(.[] | select(.id == $folderId))
          | .devices = ((.devices // []) | map(select(.deviceID != $deviceId)))' \
          <<<"$folders_json"
      )"
      api_json POST /rest/config/folders "$folder_json"
    done < <(${pkgs.jq}/bin/jq -r '.[] | [.folderIdPrefix] | @tsv' <<<"$folder_specs_json")

    remaining_refs="$(api /rest/config/folders | ${pkgs.jq}/bin/jq --arg deviceId "$device_id" '[.[].devices[]? | select(.deviceID == $deviceId)] | length')"
    if [[ "$remaining_refs" == "0" ]]; then
      devices_json="$(api /rest/config/devices)"
      if ${pkgs.jq}/bin/jq -e --arg deviceId "$device_id" \
          'any(.[]; .deviceID == $deviceId)' <<<"$devices_json" >/dev/null; then
        api /rest/config/devices/"$device_id" -X DELETE >/dev/null
      fi
    fi

    tmp="$(${pkgs.coreutils}/bin/mktemp "$state_dir/.devices.XXXXXX")"
    ${pkgs.jq}/bin/jq \
      --arg username "$username" \
      --arg deviceId "$device_id" \
      --arg updatedAt "$(${pkgs.coreutils}/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '
      def v2:
        if .version == 2 then .
        else {
          version: 2,
          users: (
            to_entries
            | map(select((.value.deviceId // "") != ""))
            | map({
              key: .key,
              value: {
                devices: [{
                  deviceId: .value.deviceId,
                  deviceName: (.value.deviceName // (.key + "-media")),
                  createdAt: (.value.updatedAt // $updatedAt),
                  updatedAt: (.value.updatedAt // $updatedAt)
                }]
              }
            })
            | from_entries
          )
        }
        end;
      v2
      | .version = 2
      | .users[$username].devices = ((.users[$username].devices // []) | map(select(.deviceId != $deviceId)))
      | if (.users[$username].devices | length) == 0 then del(.users[$username]) else . end
      ' \
      "$state_file" > "$tmp"
    chmod 0640 "$tmp"
    chown root:root "$tmp"
    mv "$tmp" "$state_file"

    if api /rest/config/restart-required | ${pkgs.jq}/bin/jq -e '.requiresRestart == true' >/dev/null; then
      ${pkgs.systemd}/bin/systemctl restart syncthing.service
    fi

    status_json="$(${offlineMediaStatus} "$username")"
    ${pkgs.jq}/bin/jq -n \
      --arg username "$username" \
      --arg removedDeviceId "$device_id" \
      --argjson status "$status_json" \
      '{
        ok: true,
        username: $username,
        removedDeviceId: $removedDeviceId,
        folders: $status.folders,
        devices: $status.devices
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
      logoUrl = "/logos/photos.svg";
      appName = "immich";
      uploadNotes = "Upload through Immich web or the mobile app.";
      requiredAnyGroups = [ "immich-users" ];
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
      logoUrl = "/logos/documents.svg";
      appName = "paperless-ngx";
      uploadNotes = "Upload PDFs and image documents through Paperless or the consume inbox.";
      requiredAnyGroups = [ "paperless-users" ];
    }
    {
      id = "files";
      name = "Files";
      url = "https://${filesHost}";
      enabled = filesEnabled;
      category = "files";
      description = "Browser file workspace backed by each user's restricted SFTP root.";
      loginNotes = "Requires ${filesWebAccessGroup} for browser access.";
      projectUrl = "https://www.filestash.app";
      logoUrl = "/logos/files.svg";
      appName = "filestash";
      uploadNotes = "Use Files for general uploads and app-specific media folders.";
      requiredAnyGroups = [ filesWebAccessGroup ];
    }
    {
      id = "audiobooks";
      name = "Audiobooks";
      url = "https://${audiobooksHost}/audiobookshelf/";
      enabled = audiobookshelfEnabled;
      category = "media";
      description = "Audiobooks and long-form audio libraries.";
      loginNotes = "Use Kanidm. The configured server operator owns the Audiobookshelf root account; app-admin does not grant Audiobookshelf administrator rights.";
      projectUrl = "https://www.audiobookshelf.org";
      logoUrl = "/logos/audiobooks.svg";
      appName = "audiobookshelf";
      uploadNotes = "Place audiobook folders under _Audiobooks.";
      requiredAnyGroups = [ "audiobookshelf-users" ];
    }
    {
      id = "videos";
      name = "Videos";
      url = "https://${videosHost}";
      enabled = jellyfinEnabled;
      category = "media";
      description = "Metadata-rich movie and show libraries.";
      loginNotes = "Jellyfin uses a generated local password, not Kanidm SSO. Ask an administrator for your initial password, sign in with your Kanidm username, then change the password immediately.";
      projectUrl = "https://jellyfin.org";
      logoUrl = "/logos/videos.svg";
      appName = "jellyfin";
      uploadNotes = "Place movies under _Videos/_Movies and series under _Videos/_Shows.";
      requiredAnyGroups = [ "jellyfin-users" ];
    }
    {
      id = "requests";
      name = "Requests";
      url = "https://${requestsHost}";
      enabled = seerrEnabled;
      category = "media";
      description = "Jellyfin-oriented movie and show request manager.";
      loginNotes = "Requires media-automation-users through Kanidm.";
      projectUrl = "https://github.com/Fallenbagel/jellyseerr";
      logoUrl = "/logos/seerr.svg";
      appName = "seerr";
      uploadNotes = "Approved requests are handed to Sonarr and Radarr.";
      requiredAnyGroups = [ "media-automation-users" ];
    }
    {
      id = "sonarr";
      name = "TV Show Downloads";
      url = "https://${sonarrHost}";
      enabled = sonarrEnabled;
      category = "media";
      description = "TV show monitoring and legal download automation.";
      loginNotes = "Requires media-automation-users through Kanidm.";
      projectUrl = "https://sonarr.tv";
      appName = "sonarr";
      uploadNotes = "Imported shows land in shared _Videos/_Shows.";
      requiredAnyGroups = [ "media-automation-users" ];
    }
    {
      id = "radarr";
      name = "Movie Downloads";
      url = "https://${radarrHost}";
      enabled = radarrEnabled;
      category = "media";
      description = "Movie monitoring and legal download automation.";
      loginNotes = "Requires media-automation-users through Kanidm.";
      projectUrl = "https://radarr.video";
      appName = "radarr";
      uploadNotes = "Imported movies land in shared _Videos/_Movies.";
      requiredAnyGroups = [ "media-automation-users" ];
    }
    {
      id = "prowlarr";
      name = "Prowlarr";
      url = "https://${prowlarrHost}";
      enabled = prowlarrEnabled;
      category = "media";
      description = "Indexer manager for Sonarr and Radarr.";
      loginNotes = "Requires media-automation-users through Kanidm.";
      projectUrl = "https://prowlarr.com";
      appName = "prowlarr";
      uploadNotes = "Add only legal indexers and sources.";
      requiredAnyGroups = [ "media-automation-users" ];
    }
    {
      id = "torrents";
      name = "Torrents";
      url = "https://${torrentsHost}";
      enabled = qbittorrentEnabled;
      category = "media";
      description = "qBittorrent download client for legally sourced media.";
      loginNotes = "Requires media-automation-users through Kanidm.";
      projectUrl = "https://www.qbittorrent.org";
      appName = "qbittorrent";
      uploadNotes = "Completed downloads are staged under shared _Downloads.";
      requiredAnyGroups = [ "media-automation-users" ];
    }
    {
      id = "offline-media";
      name = "Offline Media";
      url = "/services/offline-media";
      enabled = offlineMediaEnabledForHomepage;
      category = "media";
      description = "Automatically keep copies of your server music and videos on a computer or phone.";
      loginNotes = offlineMediaLoginNotes;
      projectUrl = "https://syncthing.net";
      appName = "syncthing";
      uploadNotes = "Add media with the Files app first; this service then copies it to your connected devices.";
      requiredAllGroups = offlineMediaRequiredAllGroups;
      requiredAnyGroups = offlineMediaRequiredAnyGroups;
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
      logoUrl = "/logos/books.svg";
      appName = "kavita";
      uploadNotes = "Place books under _Books/_Ebooks, _Comics, or _Manga.";
      requiredAnyGroups = [ "kavita-users" ];
    }
    {
      id = "wiki";
      name = "Offline Wiki";
      url = "https://${wikiHost}";
      enabled = kiwixEnabled;
      category = "knowledge";
      description = "Kiwix ZIM library for offline reference material.";
      loginNotes = "Use Kanidm with kiwix-users membership.";
      projectUrl = "https://kiwix.org";
      appName = "kiwix";
      uploadNotes = "Operators upload .zim files to the configured Kiwix library root.";
      requiredAnyGroups = [ "kiwix-users" ];
    }
    {
      id = "emails";
      name = "Mail Archive";
      url = "https://${emailsHost}";
      enabled = mailArchiveEnabled;
      category = "knowledge";
      description = "Private mail search, attachment export, and Paperless handoff.";
      loginNotes = "Requires mail-archive-users.";
      logoUrl = "/logos/mail-archive.svg";
      appName = "custom app with notmuch / maildir";
      uploadNotes = "Synced mail appears as visible .eml mirrors under _Emails.";
      requiredAnyGroups = [ "mail-archive-users" ];
    }
    {
      id = "downloads";
      name = "Youtube Downloads";
      url = "https://${downloadsHost}";
      enabled = youtubeDownloaderEnabled;
      category = "media";
      description = "Authenticated yt-dlp queue for audio and video downloads.";
      loginNotes = "Requires downloads-users.";
      projectUrl = "https://github.com/yt-dlp/yt-dlp";
      appName = "custom app with yt-dlp";
      uploadNotes = "Downloads land in personal or shared media folders.";
      requiredAnyGroups = [ "downloads-users" ];
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
      logoUrl = "/logos/passwords.svg";
      appName = "vaultwarden";
      uploadNotes = "Store Kanidm credentials, recovery codes, and app-local passwords here.";
    }
    {
      id = "backups";
      name = "Local Backups";
      url = "https://${backupsHost}";
      enabled = kopiaEnabled;
      category = "operations";
      description = "Kopia backup management for critical state, Paperless data, and consistent database dumps.";
      loginNotes = "Requires ${vars.backupAdminGroup} plus the native Kopia password.";
      projectUrl = "https://kopia.io";
      appName = "kopia";
      uploadNotes = "Backup repository files are managed by Kopia.";
      requiredAnyGroups = [ vars.backupAdminGroup ];
    }
    {
      id = "monitor";
      name = "Monitor";
      url = "https://${monitorHost}";
      enabled = monitorEnabled;
      category = "operations";
      description = "Beszel monitoring dashboard for host resources, app units, storage, and disk health.";
      loginNotes = "Requires ${vars.monitoringAccessGroup} through Kanidm, then the native Beszel login.";
      projectUrl = "https://beszel.dev";
      appName = "beszel";
      uploadNotes = "Monitoring state is managed by Beszel.";
      requiredAnyGroups = [ vars.monitoringAccessGroup ];
    }
  ];

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
        "Pure audio with thumbnails belongs in Audiobookshelf, not Jellyfin."
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

  zfsStorageAdminGuide = lib.optionals vars.enableZfsDataPool [
    {
      title = "Check ZFS pool status";
      command = "zpool status -v ${vars.zfsDataPool.name}";
      detail = "Inspect data pool health, mirror state, scrub history, checksums, and device errors.";
    }
    {
      title = "Start ZFS scrub";
      command = "sudo zpool scrub ${vars.zfsDataPool.name}";
      detail = "Start a scrub for the mirrored data pool. Monitor progress and any repaired errors with the ZFS pool status command.";
    }
    {
      title = "Show Btrfs filesystem usage";
      command = "sudo btrfs filesystem usage /persist";
      detail = "Check Btrfs allocation and data/metadata usage for persistent state on the system SSD.";
    }
    {
      title = "Check Btrfs scrub status";
      command = "sudo btrfs scrub status /persist";
      detail = "Review the latest Btrfs scrub result for persistent state on the system SSD.";
    }
  ];
  singleDiskStorageAdminGuide = lib.optionals (!vars.enableZfsDataPool) [
    {
      title = "Check root filesystem usage";
      command = "df -hT / ${vars.dataRoot} /persist";
      detail = "Check free space and filesystem types for the single-disk root, data root directory, and persistent state directory.";
    }
    {
      title = "Inspect root mount options";
      command = "findmnt -no SOURCE,FSTYPE,OPTIONS /";
      detail = "Confirm the root device, filesystem type, and active mount options on the single-disk ext4 profile.";
    }
    {
      title = "Check storage layout logs";
      command = "sudo journalctl -u data-pool-layout.service -n 100 --no-pager";
      detail = "Review creation and repair logs for data, appdata, shared, backup, and user-root directories.";
    }
    {
      title = "Inspect system disk with SMART";
      command = "sudo smartctl -a /dev/disk/by-id/${vars.mainDisk}";
      detail = "Read SMART attributes, self-test history, and error logs for the single system disk.";
    }
  ];

  adminGuide = [
    {
      title = "Review evaluated config";
      command = "nix run .#show-config-summary";
      detail = "Read-only summary of generated hostnames, app surfaces, access groups, OAuth clients, storage paths, and required secrets. Start here before changing config.";
    }
    {
      title = "Validate config readiness";
      command = "nix run .#validate-config-readiness -- --identity /secure/path/to/age.key";
      detail = "From the repository, preflight evaluated settings, decryptability of required secrets, and bootstrap/deploy prerequisites. Replace the identity path first. This check does not prove SSH or network reachability.";
    }
    {
      title = "Export operations inventory";
      command = "nix run .#export-inventory -- --format text";
      detail = "Print the evaluated inventory for hostnames, identity, storage, backups, impermanence, secrets, and systemd units. Use this for audits or handoff notes.";
    }
    {
      title = "Check git worktree";
      command = "git status --short";
      detail = "Confirm modified, staged, and untracked files before the guarded deploy packages the repo archive. New Nix files must be tracked to reach the server.";
    }
    {
      title = "Check service health";
      command = "sudo systemctl --failed --no-pager";
      detail = "List failed units after deploys or incidents. Follow up with status and logs for each named unit.";
    }
    {
      title = "List scheduled timers";
      command = "systemctl list-timers --all --no-pager";
      detail = "Review backup, sync, reconciliation, scrub, and maintenance timers, including missed or inactive schedules.";
    }
    {
      title = "Review current boot warnings";
      command = "journalctl -b -p warning..alert --no-pager";
      detail = "Scan current-boot warnings and errors to spot host-level failures before narrowing to one app.";
    }
    {
      title = "Show resource snapshot";
      command = "systemctl status --no-pager";
      detail = "Get a quick systemd snapshot showing degraded state, queued jobs, failed units, and resource summary.";
    }
    {
      title = "Validate broad changes";
      command = "./scripts/deploy.sh --debug --action test";
      detail = "Run the broad validation gate and test-activate the candidate on the live server after a significant change. Test activation changes running services, but does not make the generation the next boot default.";
    }
    {
      title = "Run lean repo validation";
      command = "./scripts/validate-repo.sh";
      detail = "Run fast repository policy and script tests before routine edits. This avoids Nix builds unless extra flags are used.";
    }
    {
      title = "Run full repo validation";
      command = "./scripts/validate-repo.sh --full";
      detail = "Run flake evaluation, repository policy tests, and buildable check derivations before broad or risky changes.";
    }
    {
      title = "Evaluate flake without building";
      command = "nix flake check --no-build";
      detail = "Catch flake evaluation errors, missing imports, and option assertion failures without building packages or switching the host.";
    }
    {
      title = "Dry-run deploy target resolution";
      command = "DEPLOY_DRY_RUN=1 ./scripts/deploy.sh --action test";
      detail = "Print the target host, build host, flake host, action, debug mode, and rebuild command the guarded deploy helper would use.";
    }
    {
      title = "Run routine guarded deploy";
      command = "./scripts/deploy.sh --action test";
      detail = "Stage the repo archive and test-activate it on the live server. Running services can restart or change; the candidate is not made the next boot default.";
    }
    {
      title = "Run guarded deploy with local build";
      command = "./scripts/deploy.sh --build-locally --action test";
      detail = "Build on the admin workstation and test-activate the live server over SSH. Running services can restart or change, even though the boot default is unchanged.";
    }
    {
      title = "Switch after a passing test";
      command = "./scripts/deploy.sh --action switch";
      detail = "Make the tested generation persistent using the guarded deploy helper. Run this only after the test path passes and failed units are understood.";
    }
    {
      title = "Show generations for rollback";
      command = "sudo nix-env --list-generations --profile /nix/var/nix/profiles/system";
      detail = "List bootable system generations and timestamps before choosing a rollback or comparing recent switches.";
    }
    {
      title = "Emergency rollback current generation";
      command = "sudo nixos-rebuild switch --rollback";
      detail = "Emergency server-console recovery only. This bypasses the guarded deploy health checks and changes both running services and the boot profile, so it may interrupt SSH. Use the guarded deploy's automatic rollback for normal failures; after this command, check failed units and routes before leaving the console.";
    }
    {
      title = "Check app service status";
      command = "systemctl status APP.service --no-pager";
      detail = "Replace APP.service with the real unit, such as immich-server.service, paperless-web.service, jellyfin.service, or filestash.service.";
    }
    {
      title = "Follow app logs";
      command = "journalctl -fu APP.service";
      detail = "Stream one unit's logs while reproducing an app problem. Stop with Ctrl-C.";
    }
    {
      title = "Restart a single app service";
      command = "sudo systemctl restart APP.service";
      detail = "Restart only the affected unit after checking logs and config. Prefer this over broad host restarts.";
    }
    {
      title = "Restart homepage";
      command = "sudo systemctl restart homepage.service";
      detail = "Recover a crashed or stuck portal using the Homepage code and generated JSON already in the active NixOS generation. Repository code or configuration changes require a guarded deploy; restarting alone cannot load them.";
    }
    {
      title = "Check OAuth proxy logs";
      command = "journalctl -u '*oauth2-proxy.service' -b --no-pager";
      detail = "Inspect SSO proxy failures across protected app surfaces, including bad upstreams, cookie issues, and denied groups.";
    }
    {
      title = "List storage layout services";
      command = "systemctl list-units --type=service --all '*storage-layout*' '*folder-layout*' fileshare-user-root-sync.service --no-pager";
      detail = "Inspect the exact layout and ACL reconciliation units available in this generation. Successful oneshot units remain active, so `start` is a no-op; after checking the data mount and logs, re-run one specific unit with `sudo systemctl restart UNIT.service`.";
    }
  ]
  ++ lib.optionals immichEnabled [
    {
      title = "Re-run Immich OIDC reconcile";
      command = "sudo systemctl start immich-oidc-reconcile.service immich-admin-reconcile.service";
      detail = "Force Immich user and admin reconciliation from current Kanidm group and claim state after access or admin-group changes.";
    }
  ]
  ++ lib.optionals paperlessEnabled [
    {
      title = "Re-run Paperless OIDC reconcile";
      command = "sudo systemctl start paperless-oidc-reconcile.service";
      detail = "Force Paperless account reconciliation from Kanidm after access, username, or email changes when the web UI has not caught up.";
    }
  ]
  ++ lib.optionals jellyfinEnabled [
    {
      title = "Retrieve Jellyfin initial password";
      command = "sudo jellyfin-initial-credential\nsudo jellyfin-initial-credential USERNAME";
      detail = "List users whose root-only initial credential is still stored, then retrieve only the intended username. Treat the printed password as a secret, hand it to that user through a trusted channel, and require them to change it after their first Jellyfin login. The stored credential can be stale after that change; reconciliation does not overwrite the replacement password.";
    }
    {
      title = "Re-run Jellyfin library sync";
      command = "sudo systemctl start jellyfin-library-sync.service";
      detail = "Refresh Jellyfin libraries after media folders are created, repaired, or populated.";
    }
  ]
  ++ lib.optionals kiwixEnabled [
    {
      title = "Re-run Kiwix library sync";
      command = "sudo systemctl start kiwix-library-sync.service";
      detail = "Publish newly uploaded or repaired ZIM files into the Kiwix web library catalog.";
    }
  ]
  ++ lib.optionals offlineMediaEnabledForHomepage [
    ({
      title = "Revoke offline-media device access";
      detail =
        if offlineMediaAccessGroup == "users" then
          "Offline Media currently uses the baseline users group. Never remove that group merely to stop device sync: doing so also removes ordinary Homepage and identity access. Have the user open Offline Media and remove each enrolled device. For centrally controlled revocation, configure a new dedicated offlineMedia.accessGroup, deploy it, and grant that role explicitly."
        else
          "Remove only the dedicated offline-media role, then immediately reconcile. Reconciliation verifies live Kanidm membership before detaching that user's stale Syncthing folders and devices; it never deletes source media or removes baseline users access.";
    } // lib.optionalAttrs (offlineMediaAccessGroup != "users") {
      command = "kanidm group remove-members ${lib.escapeShellArg offlineMediaAccessGroup} USERNAME\nsudo systemctl start offline-media-reconcile.service";
    })
  ]
  ++ [
    {
      title = "Check Kanidm health";
      command = "systemctl status kanidm.service --no-pager";
      detail = "Check the identity provider before debugging app sign-in, OAuth, or group-claim failures.";
    }
    {
      title = "Bootstrap or recover operator credential";
      command = "sudo kanidm-operator-bootstrap status\n# If status says initial setup is required:\nsudo kanidm-operator-bootstrap issue";
      detail = "On the server, check whether the configured operator has completed credential setup. `issue` prints a short-lived one-time setup URL only to the root terminal. For a deliberate later recovery, review the warning and add `--recovery`; never paste the URL into logs or tickets.";
    }
    {
      title = "Authenticate Kanidm CLI";
      command = "kanidm login -D ${lib.escapeShellArg vars.kanidmAdminUser} && kanidm self whoami";
      detail = "Start or verify a CLI session as the configured delegated operator before running person or group commands. Do not use the built-in idm_admin account for routine administration.";
    }
    {
      title = "List Kanidm people";
      command = "kanidm person list";
      detail = "Review known people before creating accounts, granting access, or removing stale access.";
    }
    {
      title = "List Kanidm groups";
      command = "kanidm group list";
      detail = "Review available groups before granting app, file, backup, or admin access.";
    }
    {
      title = "Inspect Kanidm group";
      command = "kanidm group get app-admin";
      detail = "Inspect membership and attributes for a specific group. Replace app-admin with the app, file, backup, or admin group you are checking.";
    }
    {
      title = "Remove user from access group";
      command = "kanidm group remove-members app-admin USERNAME";
      detail = "Use this live command only for a manual/additive group such as app-admin or a file-access role, after verifying membership. First search vars.nix for the username: configured seed members must also be removed from their source list and deployed or provisioning can add them again. Application bundles and backup roles reconcile exactly and must be changed in vars.nix.";
    }
    {
      title = "Restart identity reconciliation";
      command = "sudo systemctl start kanidm-identity-reconcile.service kanidm-files-posix-groups.service fileshare-user-root-sync.service";
      detail = "Refresh configured display names and mail addresses for Kanidm people that already exist, then refresh POSIX file-group mappings and per-user roots. This does not create a missing person or change repository-managed group membership; edit vars.nix and deploy for those changes.";
    }
    {
      title = "Manage Kanidm entity removal explicitly";
      command = "$EDITOR modules/Core_Modules/kanidm/provision.nix";
      detail = "Kanidm autoremove is disabled, so deleted module groups/users are kept for rescue safety. Mark stale provision entries intentionally, for example with `present = false`, before retiring a module or host.";
    }
    {
      title = "Show mounted filesystems";
      command = "df -hT";
      detail = "Check free space and filesystem types for mounted roots, content pools, persistent state, and backup paths.";
    }
    {
      title = "Show disk layout";
      command = "lsblk -f";
      detail = "Review block devices, filesystems, labels, UUIDs, and mountpoints before storage or recovery work.";
    }
    {
      title = "Discover monitored storage devices";
      command = "sudo nixhomeserver-storage-inventory --format text";
      detail = "On the server, list disks detected by the evaluated storage-monitoring inventory, including stable by-id paths to use in config. This installed command cannot accidentally inspect an admin workstation.";
    }
  ]
  ++ zfsStorageAdminGuide
  ++ singleDiskStorageAdminGuide
  ++ [
    {
      title = "Run SMART short sweep";
      command = "sudo systemctl start storage-smart-short.service";
      detail = "On the server, start short SMART self-tests for the evaluated monitored-device inventory. Check the storage monitor logs after the tests complete.";
    }
    {
      title = "Inspect a disk with SMART";
      command = "sudo smartctl -a /dev/disk/by-id/REPLACE_DISK_ID";
      detail = "Read SMART attributes, self-test history, and error logs for one disk. Use a stable /dev/disk/by-id path.";
    }
    {
      title = "Check storage monitor logs";
      command = "journalctl -u 'storage-smart-*' -u smartd.service -b --no-pager";
      detail = "Inspect SMART sweep and smartd output from the current boot, including failed self-tests and alert messages.";
    }
    {
      title = "Check backup timers";
      command = "systemctl list-timers 'kopia*' 'rclone*' --all --no-pager";
      detail = "Verify Kopia snapshot timers${lib.optionalString megaEnabled " and the configured offsite sync timer"} are scheduled and see their next run times.";
    }
    {
      title = "Check Kopia services";
      command = "systemctl status kopia.service kopia-auth-proxy.service auth-gateway-oauth2-proxy.service auth-gateway-router.service --no-pager";
      detail = "Inspect the local Kopia server, native auth proxy, and shared SSO gateway together when backup UI or auth is failing.";
    }
    {
      title = "Run persist snapshot now";
      command = "sudo systemctl start kopia-persist-snapshot.service";
      detail = "Trigger an immediate snapshot of persisted system and app state. Check logs before assuming it completed.";
    }
    {
      title = "Inspect persist snapshot logs";
      command = "journalctl -u kopia-persist-snapshot.service -n 100 --no-pager";
      detail = "Review the most recent persist snapshot run, including Kopia errors and excluded paths.";
    }
  ]
  ++ lib.optionals megaEnabled [
    {
      title = "Run offsite Kopia sync now";
      command = "sudo systemctl start rclone-mega-kopia-sync.service";
      detail = "Start the rclone job that mirrors the Kopia repository offsite. Use after a successful local snapshot when freshness matters.";
    }
    {
      title = "Inspect offsite sync logs";
      command = "journalctl -u rclone-mega-kopia-sync.service -n 100 --no-pager";
      detail = "Review the most recent offsite backup sync run, including transfer failures and destination errors.";
    }
  ]
  ++ [
    {
      title = "Check backup repository size";
      command = "sudo du -sh ${vars.backupRoot}/kopia";
      detail = "Check the managed Kopia repository's on-disk size before storage, retention, or offsite sync troubleshooting.";
    }
    {
      title = "Check Caddy status";
      command = "systemctl status caddy.service --no-pager";
      detail = "Check the edge reverse proxy before debugging public or private app reachability.";
    }
    {
      title = "Validate Caddy config";
      command = "nix run --inputs-from . nixpkgs#caddy -- validate --config /etc/caddy/caddy_config --adapter caddyfile";
      detail = "Validate the running Caddy config file before reloads, route changes, or TLS debugging. A valid Nix build can still produce a bad runtime route.";
    }
    {
      title = "Reload Caddy";
      command = "sudo systemctl reload caddy.service";
      detail = "Reload the Caddy configuration already present in the active NixOS generation. Repository route changes must be deployed first; editing the repo and reloading cannot apply them.";
    }
    {
      title = "Inspect Caddy logs";
      command = "journalctl -u caddy.service -b --no-pager";
      detail = "Review reverse proxy, TLS, ACME, and upstream errors from the current boot.";
    }
    {
      title = "Check Unbound status";
      command = "systemctl status unbound.service --no-pager";
      detail = "Check private DNS health before debugging split-horizon records or NetBird-only routes.";
    }
    {
      title = "Query private DNS";
      command = "dig @${vars.networking.loopbackIPv4} homepage.${vars.domain}";
      detail = "Confirm the server's loopback resolver returns the private homepage record before debugging clients or NetBird routes.";
    }
    {
      title = "Check Cloudflare tunnel status";
      command = "systemctl status 'cloudflared-tunnel-${vars.cloudflareTunnelName}.service' --no-pager";
      detail = "Inspect the Cloudflare tunnel unit when public hostnames fail but local services still work.";
    }
    {
      title = "Inspect Cloudflare tunnel logs";
      command = "journalctl -u 'cloudflared-tunnel-${vars.cloudflareTunnelName}.service' -b --no-pager";
      detail = "Review tunnel registration, connection, DNS, and ingress errors from the current boot.";
    }
    {
      title = "Check NetBird status";
      command = "netbird-main status";
      detail = "Confirm the server is connected to NetBird and advertises or receives the expected peers and routes.";
    }
    {
      title = "Inspect firewall rules";
      command = "sudo nft list ruleset";
      detail = "Inspect active nftables rules when DNS resolves and the service runs, but traffic is still blocked.";
    }
    {
      title = "Show SFTP host key fingerprint";
      command = "sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub";
      detail = "Give this fingerprint to an SFTP/SSHFS user through a trusted channel before their first connection. Investigate rather than accepting an unexpected fingerprint change.";
    }
    {
      title = "Rotate or regenerate secrets";
      command = "nix run .#generate-secrets -- --identity /path/to/current/age.key";
      detail = "Verify every manifest secret with the current identity. Use the documented explicit --fresh or --rekey mode only when intentionally changing credentials or recipients.";
    }
    {
      title = "List encrypted secrets";
      command = "find secrets -maxdepth 1 -name '*.age' -printf '%f\\n' | sort";
      detail = "Review encrypted age files tracked in the repository without exposing plaintext secret values.";
    }
    {
      title = "List expected external secrets";
      command = "nix eval --json --impure --expr 'builtins.attrNames ((import ./secrets/manifest.nix).externalSecrets)'";
      detail = "Print external secret names that must be supplied from staged material rather than generated automatically.";
    }
    {
      title = "Edit staged external secret";
      command = "$EDITOR secrets/unencrypted/SECRET_NAME";
      detail = "Create or update one staged plaintext external secret immediately before encryption. Replace SECRET_NAME with a manifest entry.";
    }
    {
      title = "Encrypt staged external secrets";
      command = "nix run .#generate-secrets -- --replace-external SECRET_NAME --identity /path/to/current/age.key";
      detail = "Validate and replace one named external manifest secret without rotating unrelated generated credentials. Securely remove its staged plaintext after verifying the result.";
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
          text = "Your SFTP root includes /${filesSharedMountName}, a shared household view. It is writable but deletion-protected so shared files cannot be removed through this view.";
          requiredAnyGroups = [ filesSharedAccessGroup ];
        }
        {
          text = "Your SFTP root includes /${filesUsbMountName} for external USB storage. It is writable but deletion-protected, and it may be empty until an administrator mounts the USB device.";
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
          address = "tcp://${syncthingHost}:22000";
          label = "Recommended server address";
        }
        {
          address = "tcp://${vars.networking.lan.ip}:22000";
          label = "At home (LAN)";
        }
        {
          address = "tcp://${vars.networking.netbird.ip}:22000";
          label = "Away from home (NetBird)";
        }
      ];
      folders = [ ];
      devices = [ ];
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
        } // lib.optionalAttrs offlineMediaEnabledForHomepage {
          HOMEPAGE_SYNCTHING_DEVICE_ID_COMMAND = showSyncthingDeviceId;
          HOMEPAGE_OFFLINE_MEDIA_STATUS_COMMAND = offlineMediaStatus;
          HOMEPAGE_OFFLINE_MEDIA_ENROLL_COMMAND = offlineMediaEnroll;
          HOMEPAGE_OFFLINE_MEDIA_REMOVE_COMMAND = offlineMediaRemove;
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
          ReadWritePaths = [ sftpAuthorizedKeysDir ]
            ++ lib.optional offlineMediaEnabledForHomepage offlineMediaStateDir
            # The sudo helpers inherit homepage.service's mount namespace, so
            # offline-media enrollment needs this writable despite running as root.
            ++ lib.optional offlineMediaEnabledForHomepage vars.usersRoot;
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
