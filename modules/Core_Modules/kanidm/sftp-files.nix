{ lib, pkgs, vars, ... }:

let
  chrootBase = vars.fileAccess.sftpChrootBase or "/srv/files-sftp/chroots";
  sftpAccessGroup = vars.fileAccess.sftpAccessGroup or "files-sftp-users";
  usbAccessGroup = vars.fileAccess.usbAccessGroup or "usb-access";
  backupStorageAccessGroup = vars.backupAccess.storageGroup or "backup-admin";
  localSftpAccessGroup = vars.fileAccess.localSftpAccessGroup or "files-local-sftp-users";
  localAdminNeedsSftpBridge = builtins.elem vars.localAdminUser (vars.filesSftpUsers or [ ]);
  webAccessGroup = vars.fileAccess.webAccessGroup or "files-personal-users";
  sharedAccessGroup = vars.fileAccess.sharedAccessGroup or "files-shared-users";
  localBridgeFileAccessGroups = lib.filter
    (group: builtins.hasAttr group vars.fileAccessPosixGids)
    (lib.unique [
      webAccessGroup
      sftpAccessGroup
      sharedAccessGroup
      usbAccessGroup
      backupStorageAccessGroup
    ]);
  sftpKanidmGroups = [
    sftpAccessGroup
    usbAccessGroup
    backupStorageAccessGroup
  ];
  sftpUnixGroups =
    lib.unique
      (
        sftpKanidmGroups
        ++ map (group: "${group}@${vars.domain}") sftpKanidmGroups
      )
    ++ lib.optionals localAdminNeedsSftpBridge [ localSftpAccessGroup ];
  sftpAuthorizedKeysDir = "/run/files-sftp-authorized-keys";
  userSftpAuthorizedKeysDir = vars.fileAccess.userSftpAuthorizedKeysDir or "/persist/appdata/files-sftp-authorized-keys";
  filesSftpPort = vars.networking.ports.filesSftp;
  lanIface = vars.networking.interfaces.lan;
  filesSftpSshdConfig = pkgs.writeText "files-sftp-sshd_config" ''
    Port ${toString filesSftpPort}
    ListenAddress ${vars.networking.loopbackIPv4}
    ListenAddress ${vars.serverLanIP}
    Protocol 2
    HostKey /etc/ssh/ssh_host_ed25519_key
    HostKey /etc/ssh/ssh_host_rsa_key
    UsePAM yes
    PAMServiceName files-sftp-sshd
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitRootLogin no
    AllowGroups ${lib.concatStringsSep " " sftpUnixGroups}
    PubkeyAuthentication yes
    AuthorizedKeysFile ${sftpAuthorizedKeysDir}/%u ${userSftpAuthorizedKeysDir}/%u
    AllowTcpForwarding no
    PermitTunnel no
    PermitTTY no
    PermitUserEnvironment no
    GatewayPorts no
    ChrootDirectory ${chrootBase}/%u
    ForceCommand internal-sftp -u 0007 -d /files
    Subsystem sftp internal-sftp
    PidFile /run/files-sftp-sshd/sshd.pid
  '';
in
{
  services.kanidm = {
    unix.enable = true;
    unix.settings = {
      version = "2";
      default_shell = "/run/current-system/sw/bin/bash";
      home_attr = "name";
      home_alias = "name";
      kanidm = {
        pam_allowed_login_groups = [
          webAccessGroup
          sftpAccessGroup
          usbAccessGroup
          backupStorageAccessGroup
          sharedAccessGroup
        ];
      };
    };
  };

  services.openssh = {
    allowSFTP = false;
    settings = {
      UsePAM = true;
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      AllowUsers = [ vars.localAdminUser ];
    };
  };

  security.pam.services.sshd.unixAuth = lib.mkForce true;
  security.pam.services.files-sftp-sshd = {
    startSession = true;
    # The local admin account also exists in /etc/passwd, so NSS resolves the
    # bare username before Kanidm. Permit pam_unix only for this local bridge;
    # non-local file users still authenticate through pam_kanidm.
    unixAuth = lib.mkForce localAdminNeedsSftpBridge;
    rules.auth.kanidm.settings.use_first_pass = lib.mkForce false;
  };

  users.groups = lib.mkIf localAdminNeedsSftpBridge (
    {
      ${localSftpAccessGroup}.members = [ vars.localAdminUser ];
    }
    // lib.genAttrs localBridgeFileAccessGroups (group: {
      gid = vars.fileAccessPosixGids.${group};
      members = [ vars.localAdminUser ];
    })
  );

  networking.firewall.interfaces.${lanIface}.allowedTCPPorts = [ filesSftpPort ];

  systemd.tmpfiles.rules = [
    "d /srv/files-sftp 0755 root root -"
    "d ${chrootBase} 0755 root root -"
    "d ${userSftpAuthorizedKeysDir} 0755 root root -"
  ];

  systemd.services.files-sftp-chroot-layout = {
    description = "Create Files SFTP chroot base";
    wantedBy = [ "multi-user.target" ];
    before = [ "sshd.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root /srv/files-sftp
      ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root ${chrootBase}
    '';
  };

  systemd.services.files-sftp-sshd = {
    description = "Dedicated OpenSSH SFTP endpoint for Filestash and file clients";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "files-sftp-chroot-layout.service"
      "fileshare-user-root-sync.service"
      "filestash-secret-materialize.service"
      "kanidm-unixd.service"
      "network-online.target"
      "sshd-keygen.service"
    ];
    after = [
      "files-sftp-chroot-layout.service"
      "fileshare-user-root-sync.service"
      "filestash-secret-materialize.service"
      "kanidm-unixd.service"
      "network-online.target"
      "sshd-keygen.service"
    ];
    serviceConfig = {
      Type = "simple";
      RuntimeDirectory = "files-sftp-sshd";
      ExecStartPre = "${pkgs.openssh}/bin/sshd -t -f ${filesSftpSshdConfig}";
      ExecStart = "${pkgs.openssh}/bin/sshd -D -e -f ${filesSftpSshdConfig}";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  systemd.services.sshd = {
    wants = [
      "files-sftp-chroot-layout.service"
      "fileshare-user-root-sync.service"
      "kanidm-unixd.service"
    ];
    after = [
      "files-sftp-chroot-layout.service"
      "fileshare-user-root-sync.service"
      "kanidm-unixd.service"
    ];
  };
}
