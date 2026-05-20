{ config, lib, pkgs, utils, vars, ... }:

let
  cfg = config.services.kanidm;
  chrootRoot = "/srv/filestash-sftp/chroot";
  authorizedKeysCommand = "/etc/ssh/kanidm_ssh_authorizedkeys";
  sftpGroup = "user-files@${vars.domain}";
  sftpUsers = "${vars.kanidmAdminUser},${vars.kanidmAdminUser}@${vars.domain}";
  sftpMatchConfig = ''
    ChrootDirectory ${chrootRoot}
    ForceCommand internal-sftp -d /
    AllowTcpForwarding no
    X11Forwarding no
    PermitTTY no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
  '';
  personalMountUnit = "${utils.escapeSystemdPath "${chrootRoot}/Personal"}.mount";
  sharedMountUnit = "${utils.escapeSystemdPath "${chrootRoot}/Shared"}.mount";
  bindMountOptions = [
    "bind"
    "x-systemd.requires=filestash-sftp-chroot-layout.service"
    "x-systemd.after=filestash-sftp-chroot-layout.service"
    "x-systemd.requires=data-pool-layout.service"
    "x-systemd.after=data-pool-layout.service"
    "x-systemd.before=sshd.service"
  ];
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
      pam_allowed_login_groups = [ "user-files" ];
      kanidm = {
        pam_allowed_login_groups = [ "user-files" ];
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
      Match User ${sftpUsers}
      ${sftpMatchConfig}

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
    "d /srv/filestash-sftp 0755 root root -"
    "d ${chrootRoot} 0755 root root -"
    "d ${chrootRoot}/Personal 0755 root root -"
    "d ${chrootRoot}/Shared 0755 root root -"
  ];

  systemd.services.filestash-sftp-chroot-layout = {
    description = "Create Filestash SFTP chroot mountpoints";
    wantedBy = [ "multi-user.target" ];
    before = [
      personalMountUnit
      sharedMountUnit
    ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root /srv/filestash-sftp
      ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root ${chrootRoot}
      ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root ${chrootRoot}/Personal
      ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root ${chrootRoot}/Shared
    '';
  };

  fileSystems."${chrootRoot}/Personal" = {
    device = vars.usersRoot;
    fsType = "none";
    options = bindMountOptions;
  };

  fileSystems."${chrootRoot}/Shared" = {
    device = vars.sharedRoot;
    fsType = "none";
    options = bindMountOptions;
  };

  systemd.services.sshd = {
    wants = [
      personalMountUnit
      sharedMountUnit
      "kanidm-unixd.service"
      "kanidm-ssh-authorizedkeys-wrapper.service"
    ];
    after = [
      personalMountUnit
      sharedMountUnit
      "kanidm-unixd.service"
      "kanidm-ssh-authorizedkeys-wrapper.service"
    ];
  };
}
