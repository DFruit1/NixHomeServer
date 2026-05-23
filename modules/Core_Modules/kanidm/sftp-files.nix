{ config, lib, pkgs, vars, ... }:

let
  cfg = config.services.kanidm;
  chrootBase = vars.fileAccess.sftpChrootBase or "/srv/files-sftp/chroots";
  authorizedKeysCommand = "/etc/ssh/kanidm_ssh_authorizedkeys";
  sftpAccessGroup = vars.fileAccess.sftpAccessGroup or "files-sftp-users";
  webAccessGroup = vars.fileAccess.webAccessGroup or "user-files";
  sftpGroup = "${sftpAccessGroup}@${vars.domain}";
  sftpUsers = vars.filesSftpUsers or [ ];
  sftpUserPrincipals =
    lib.concatStringsSep ","
      (sftpUsers ++ map (user: "${user}@${vars.domain}") sftpUsers);
  sftpMatchConfig = ''
    ChrootDirectory ${chrootBase}/%u
    ForceCommand internal-sftp -d /
    AllowTcpForwarding no
    X11Forwarding no
    PermitTTY no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
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
      AuthorizedKeysCommand = "${authorizedKeysCommand} %u";
      AuthorizedKeysCommandUser = "nobody";
    };
    extraConfig = lib.mkAfter ''
      ${lib.optionalString (sftpUserPrincipals != "") ''
      Match User ${sftpUserPrincipals}
      ${sftpMatchConfig}
      ''}

      Match Group ${sftpGroup}
      ${sftpMatchConfig}
    '';
  };

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
