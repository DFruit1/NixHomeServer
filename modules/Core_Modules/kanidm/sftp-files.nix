{ config, lib, pkgs, vars, ... }:

let
  cfg = config.services.kanidm;
  chrootBase = vars.fileAccess.sftpChrootBase or "/srv/files-sftp/chroots";
  authorizedKeysCommand = "/etc/ssh/kanidm_ssh_authorizedkeys";
  sftpAccessGroup = vars.fileAccess.sftpAccessGroup or "files-sftp-users";
  webAccessGroup = vars.fileAccess.webAccessGroup or "user-files";
  sftpGroup = "${sftpAccessGroup}@${vars.domain}";
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
    PasswordAuthentication yes
    KbdInteractiveAuthentication yes
    PubkeyAuthentication no
    PermitRootLogin no
    AllowGroups ${sftpGroup}
    AuthorizedKeysCommand none
    GSSAPIAuthentication no
    KerberosAuthentication no
    X11Forwarding no
    AllowTcpForwarding no
    PermitTunnel no
    PermitTTY no
    PermitUserEnvironment no
    GatewayPorts no
    ChrootDirectory ${chrootBase}/%u
    ForceCommand internal-sftp -d /
    Subsystem sftp internal-sftp
    PidFile /run/files-sftp-sshd/sshd.pid
  '';
in
{
  services.kanidm = {
    enablePam = true;
    unixSettings = {
      version = "2";
      default_shell = "/run/current-system/sw/bin/bash";
      home_attr = "name";
      home_alias = "name";
      # The pinned NixOS module exposes the old top-level option, while the
      # Kanidm 1.9 unix daemon expects this under [kanidm] for version 2.
      pam_allowed_login_groups = [
        webAccessGroup
        sftpAccessGroup
      ];
      kanidm = {
        pam_allowed_login_groups = [
          webAccessGroup
          sftpAccessGroup
        ];
      };
    };
  };

  services.openssh = {
    settings = {
      UsePAM = true;
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      AuthorizedKeysCommand = "${authorizedKeysCommand} %u";
      AuthorizedKeysCommandUser = "nobody";
    };
  };

  security.pam.services.sshd.unixAuth = lib.mkForce true;

  networking.firewall.interfaces.${lanIface}.allowedTCPPorts = [ filesSftpPort ];

  systemd.services.kanidm-ssh-authorizedkeys-wrapper = {
    description = "Install root-owned Kanidm SSH authorized keys command wrapper";
    wantedBy = [ "multi-user.target" ];
    before = [ "sshd.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root /etc/ssh
      ${pkgs.coreutils}/bin/cat >${lib.escapeShellArg authorizedKeysCommand} <<'EOF'
      #!${pkgs.runtimeShell}
      exec ${cfg.package}/bin/kanidm_ssh_authorizedkeys "$@"
      EOF
      ${pkgs.coreutils}/bin/chown root:root ${lib.escapeShellArg authorizedKeysCommand}
      ${pkgs.coreutils}/bin/chmod 0755 ${lib.escapeShellArg authorizedKeysCommand}
    '';
  };

  systemd.tmpfiles.rules = [
    "d /srv/files-sftp 0755 root root -"
    "d ${chrootBase} 0755 root root -"
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
      "kanidm-unixd.service"
      "network-online.target"
      "sshd-keygen.service"
    ];
    after = [
      "files-sftp-chroot-layout.service"
      "fileshare-user-root-sync.service"
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
      "kanidm-ssh-authorizedkeys-wrapper.service"
    ];
    after = [
      "files-sftp-chroot-layout.service"
      "fileshare-user-root-sync.service"
      "kanidm-unixd.service"
      "kanidm-ssh-authorizedkeys-wrapper.service"
    ];
  };
}
