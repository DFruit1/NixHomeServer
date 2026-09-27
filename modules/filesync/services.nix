{ appPackages, lib, pkgs, vars, ... }:

let
  port = vars.networking.ports.filesyncApi;
  loopback = vars.networking.loopbackIPv4;
  usersRoot = vars.usersRoot;
  enabled = name: builtins.elem name vars.enabledApps;
  root = id: folder: service: serviceTitle: title: description: serverPath: localSubpath: direction: {
    inherit id folder service serviceTitle title description serverPath localSubpath direction;
  };
  offlineMediaModel = (import ../../lib/offline-media.nix { inherit lib; }) vars.offlineMedia;
  offlineMediaRoots = map
    (spec:
      let
        parts = lib.splitString "/" spec.relativePath;
        music = spec.key == "music";
      in
      root
        "offline-${spec.folderIdPrefix}"
        (builtins.head parts)
        "offline-media"
        "Offline Media"
        (if music then "Store personal music on your device" else "Store personal ${lib.toLower spec.label} on your device")
        (if music then "Copy your personal music into _My Music inside the folder you choose." else "Copy this personal media folder for offline use.")
        (lib.concatStringsSep "/" (builtins.tail parts))
        (if music then "_My Music" else "_My Offline Media/${spec.folderIdPrefix}")
        "server-to-phone")
    offlineMediaModel.folderSpecs;
  roots =
    (lib.optional (enabled "files") (root "files" "_Files" "files" "Files" "Keep your files on this device" "Download your personal files for offline use." "" "_My Files" "server-to-phone"))
    ++ (lib.optionals (enabled "offline-music" && (vars.offlineMedia.enable or false)) offlineMediaRoots)
    ++ (lib.optional (enabled "jellyfin") (root "videos" "_Videos" "jellyfin" "Videos" "Keep personal videos offline" "Copy your own video library to this device." "" "_My Videos" "server-to-phone"))
    ++ (lib.optional (enabled "audiobookshelf") (root "audiobooks" "_Audiobooks" "audiobookshelf" "Audiobooks" "Keep your audiobooks offline" "Copy your personal audiobook library to this device." "" "_My Audiobooks" "server-to-phone"))
    ++ (lib.optional (enabled "kavita") (root "books" "_Books" "kavita" "Books" "Keep personal books offline" "Copy your personal ebooks, comics, and manga to this device." "" "_My Books" "server-to-phone"));
  rootFolders = lib.unique (map (entry: entry.folder) roots);
  aclRoots = lib.concatMapStringsSep " " lib.escapeShellArg rootFolders;
  aclPolicyId = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON roots));
  aclMarker = "/persist/appdata/.nixos-managed/filesync-acl-policy-${aclPolicyId}";
  grantSyncAccess = pkgs.writeShellScript "filesync-grant-user-files-access" ''
    set -euo pipefail
    marker=${lib.escapeShellArg aclMarker}
    [[ -e "$marker" ]] && exit 0
    ${pkgs.acl}/bin/setfacl -m u:filesync-api:--x ${lib.escapeShellArg usersRoot}
    for folder in ${aclRoots}; do
    for files_root in ${lib.escapeShellArg usersRoot}/*/"$folder"; do
      [[ -d "$files_root" ]] || continue
      user_root="$(dirname "$files_root")"
      ${pkgs.acl}/bin/setfacl -m u:filesync-api:--x "$user_root"
      ${pkgs.acl}/bin/setfacl -R -m u:filesync-api:rwX "$files_root"
      ${pkgs.findutils}/bin/find "$files_root" -type d -exec ${pkgs.acl}/bin/setfacl -m d:u:filesync-api:rwx '{}' +
    done
    done
    install -D -m 0600 /dev/null "$marker"
  '';
in
{
  users.groups.filesync-api = { };
  users.users.filesync-api = {
    isSystemUser = true;
    group = "filesync-api";
    home = "/var/empty";
    createHome = false;
  };

  systemd.services.filesync-api = {
    description = "Kanidm-authenticated per-user file sync API";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" "kanidm.service" "fileshare-user-root-sync.service" "fileshare-acl-migrate.service" ];
    after = [ "network-online.target" "kanidm.service" "fileshare-user-root-sync.service" "fileshare-acl-migrate.service" ];
    requires = [ "data-pool-layout.service" "fileshare-user-root-sync.service" ];
    environment = {
      FILESYNC_LISTEN = "${loopback}:${toString port}";
      FILESYNC_OIDC_ISSUER = vars.kanidmIssuer "filesync-native";
      FILESYNC_OIDC_CLIENT_ID = "filesync-native";
      FILESYNC_OIDC_REDIRECT_URI = "filesync://oauth/callback";
      FILESYNC_USERS_ROOT = usersRoot;
      FILESYNC_ROOTS_JSON = builtins.toJSON roots;
    };
    serviceConfig = {
      ExecStart = "${appPackages.filesync-api}/bin/filesync-api";
      ExecStartPre = "+${grantSyncAccess}";
      User = "filesync-api";
      Group = "filesync-api";
      Restart = "on-failure";
      RestartSec = "5s";
      # The first grant recursively visits personal files. Keep it from being
      # killed and retried on large existing trees; the version marker makes
      # subsequent service restarts avoid repeating that migration.
      TimeoutStartSec = "30min";
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectProc = "invisible";
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      LockPersonality = true;
      RemoveIPC = true;
      RestrictSUIDSGID = true;
      RestrictRealtime = true;
      RestrictNamespaces = true;
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      CapabilityBoundingSet = "";
      AmbientCapabilities = "";
      UMask = "0007";
      ReadWritePaths = [ usersRoot ];
      BindReadOnlyPaths = [ "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt" ];
    };
  };
}
