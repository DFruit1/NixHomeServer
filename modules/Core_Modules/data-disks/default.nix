{ config, pkgs, ... }:

let
  repoRoot = ../../..;
  generateSmartdConfigScript = "${repoRoot}/scripts/generate-smartd-config.sh";
  systemPackages =
    (with pkgs; [
      smartmontools
    ])
    ++ [
      config.boot.zfs.package
    ];
  smartdPath = with pkgs; [
    bash
    coreutils
    jq
    smartmontools
    util-linux
    zfs
  ];
in
{
  environment.systemPackages = systemPackages;

  systemd.services.smartd = {
    description = "S.M.A.R.T. Daemon";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "zfs.target" ];
    wants = [ "zfs.target" ];
    path = smartdPath;
    preStart = ''
      install -d -m 0755 /run/storage-smartd
      ${pkgs.bash}/bin/bash ${generateSmartdConfigScript} >/run/storage-smartd/smartd.conf
    '';
    serviceConfig = {
      Type = "notify";
      ExecStart = "${pkgs.smartmontools}/sbin/smartd --no-fork --configfile=/run/storage-smartd/smartd.conf";
      RuntimeDirectory = "storage-smartd";
      Restart = "on-failure";
    };
  };
}
