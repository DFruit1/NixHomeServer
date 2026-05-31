{ appPackages, config, lib, pkgs, vars, ... }:

let
  systemPackages =
    [
      appPackages.kanidm-admin
    ];
  rootHelper = "/run/current-system/sw/bin/kanidm-admin-root";
  fileAccess = vars.fileAccess or { };
  backupAccess = vars.backupAccess or { };
  networkingPorts = vars.networking.ports or { };
  dataRoot = vars.dataRoot or "/mnt/data";
  localSftpAccessGroup = fileAccess.localSftpAccessGroup or "files-local-sftp-users";
  allowedSecretPaths =
    lib.optional
      (builtins.hasAttr "vaultwardenAdminToken" config.age.secrets)
      config.age.secrets.vaultwardenAdminToken.path;
  contextFile = "/etc/kanidm-admin/context.json";
  installedContext = {
    serverUrl = vars.kanidmBaseUrl;
    adminName = vars.kanidmAdminUser;
    vaultwardenUrl = "https://passwords.${vars.domain}";
    vaultwardenAdminTokenFile =
      if builtins.hasAttr "vaultwardenAdminToken" config.age.secrets
      then config.age.secrets.vaultwardenAdminToken.path
      else null;
    sftpRuntime = {
      sftpAccessGroup = fileAccess.sftpAccessGroup or "files-sftp-users";
      localSftpAccessGroup = fileAccess.localSftpAccessGroup or "files-local-sftp-users";
      webAccessGroup = fileAccess.webAccessGroup or "user-files";
      sharedAccessGroup = fileAccess.sharedAccessGroup or "files-shared-users";
      usbAccessGroup = fileAccess.usbAccessGroup or "usb-access";
      backupStorageAccessGroup = backupAccess.storageGroup or "admin-backups";
      sftpChrootBase = fileAccess.sftpChrootBase or "/srv/files-sftp/chroots";
      usersRoot = vars.usersRoot or "${dataRoot}/users";
      sharedRoot = vars.sharedRoot or "${dataRoot}/shared";
      usbRoot = vars.externalUsbMountRoot or "/mnt/external-usb";
      backupRoot = vars.backupRoot or "${dataRoot}/backups";
      sharedMountName = fileAccess.sharedMountName or "_Shared";
      usbMountName = fileAccess.usbMountName or "_USB";
      backupStorageMountName = backupAccess.storageMountName or "_Backups";
      filesSftpPort = networkingPorts.filesSftp or 2222;
      filesSftpSshdService = "files-sftp-sshd.service";
      kanidmUnixdService = "kanidm-unixd.service";
      posixGroupsService = "kanidm-files-posix-groups.service";
      userRootSyncService = "fileshare-user-root-sync.service";
      userRootBindTemplate = "files-sftp-user-root@.service";
      sharedBindTemplate = "files-shared-bindfs@.service";
      usbBindTemplate = "files-usb-bindfs@.service";
      backupBindTemplate = "files-backups-bindfs@.service";
    };
  };
  rootHelperSudoCommands =
    [
      {
        command = "${rootHelper} systemd-start kanidm-files-posix-groups.service";
        options = [ "NOPASSWD" ];
      }
      {
        command = "${rootHelper} systemd-start fileshare-user-root-sync.service";
        options = [ "NOPASSWD" ];
      }
      {
        command = "${rootHelper} systemd-start jellyfin.service";
        options = [ "NOPASSWD" ];
      }
      {
        command = "${rootHelper} systemd-start jellyfin-password-reconcile.service";
        options = [ "NOPASSWD" ];
      }
      {
        command = "${rootHelper} chpasswd *";
        options = [ "NOPASSWD" ];
      }
    ]
    ++ map
      (path: {
        command = "${rootHelper} read-secret ${toString path}";
        options = [ "NOPASSWD" ];
      })
      allowedSecretPaths;
in
{
  environment.systemPackages = systemPackages;

  environment.etc."kanidm-admin-root/allowed-secret-paths".text =
    (lib.concatMapStringsSep "\n" toString allowedSecretPaths)
    + lib.optionalString (allowedSecretPaths != [ ]) "\n";
  environment.etc."kanidm-admin-root/chpasswd-group".text = "${localSftpAccessGroup}\n";
  environment.etc."kanidm-admin/context.json".text = builtins.toJSON installedContext + "\n";

  systemd.tmpfiles.rules = [
    "d /var/lib/kanidm-admin 0700 ${vars.localAdminUser} users -"
    "d /var/lib/kanidm-admin/history 0700 ${vars.localAdminUser} users -"
    "d /var/lib/kanidm-admin/doctor 0700 ${vars.localAdminUser} users -"
  ];

  systemd.services.kanidm-admin-doctor = {
    description = "Capture kanidm-admin doctor status";
    environment.KANIDM_ADMIN_HISTORY_DIR = "/var/lib/kanidm-admin/history";
    path = [ pkgs.coreutils ];
    script = ''
      set -euo pipefail
      umask 077
      tmp="$(mktemp /var/lib/kanidm-admin/doctor/latest.json.tmp.XXXXXX)"
      if ${appPackages.kanidm-admin}/bin/kanidm-admin --output json doctor > "$tmp"; then
        mv "$tmp" /var/lib/kanidm-admin/doctor/latest.json
      else
        status="$?"
        mv "$tmp" /var/lib/kanidm-admin/doctor/latest.failed.json || true
        exit "$status"
      fi
    '';
    serviceConfig = {
      Type = "oneshot";
      User = vars.localAdminUser;
      Group = "users";
    };
  };

  systemd.timers.kanidm-admin-doctor = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
  };

  systemd.services.kanidm-admin-history-prune = {
    description = "Prune old kanidm-admin operation history";
    environment.KANIDM_ADMIN_HISTORY_DIR = "/var/lib/kanidm-admin/history";
    serviceConfig = {
      Type = "oneshot";
      User = vars.localAdminUser;
      Group = "users";
      ExecStart = "${appPackages.kanidm-admin}/bin/kanidm-admin history prune --older-than 90d";
    };
  };

  systemd.timers.kanidm-admin-history-prune = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  # kanidm-admin local runtime actions use this exact helper contract. The
  # broader deploy/bootstrap sudo policy is documented in base-system and is
  # reported by `kanidm-admin doctor --deep` until deploy sudo is narrowed.
  security.sudo.extraRules = [
    {
      users = [ vars.localAdminUser ];
      commands = rootHelperSudoCommands;
    }
  ];

  environment.variables = {
    KANIDM_ADMIN_CONTEXT_FILE = contextFile;
    KANIDM_ADMIN_SERVER_URL = vars.kanidmBaseUrl;
    KANIDM_ADMIN_NAME = vars.kanidmAdminUser;
    KANIDM_ADMIN_KANIDM_BIN = "${pkgs.kanidm_1_9}/bin/kanidm";
    KANIDM_ADMIN_NIX_BIN = "${pkgs.nix}/bin/nix";
    KANIDM_ADMIN_HISTORY_DIR = "/var/lib/kanidm-admin/history";
    KANIDM_ADMIN_ROOT_HELPER = rootHelper;
  };
}
