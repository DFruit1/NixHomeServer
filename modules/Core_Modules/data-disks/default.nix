{ lib, pkgs, vars, ... }:

let
  snapraidSyncTimer = "*-*-* 22:00:00";
  snapraidScrubTimer = "Sun *-*-* 10:00:00";
  mergerfsMountPoint = vars.dataRoot;
  snapraidContentFiles =
    [ "/var/lib/snapraid/snapraid.content" ]
    ++ (lib.imap0 (idx: _: "/mnt/disk${toString (idx + 1)}/snapraid.content") vars.dataDisks)
    ++ [ "/mnt/parity/snapraid.content" ];
  mergerfsSourceList =
    lib.concatStringsSep ":"
      (lib.imap0
        (idx: _: "/mnt/disk${toString (idx + 1)}")
        vars.dataDisks);
  mkSnapraidLine = idx: _:
    let
      n = toString (idx + 1);
    in
    "data d${n} /mnt/disk${n}";
  snapraidMounts =
    [ mergerfsMountPoint "/mnt/parity" ]
    ++ (lib.imap0 (idx: _: "/mnt/disk${toString (idx + 1)}") vars.dataDisks);
in
{
  environment.systemPackages = with pkgs; [
    mergerfs
    snapraid
    smartmontools
  ];

  fileSystems.${mergerfsMountPoint} = {
    fsType = "fuse.mergerfs";
    device = mergerfsSourceList;
    options =
      [
        "defaults"
        "allow_other"
        "use_ino"
        "minfreespace=10G"
        "category.create=epmfs"
      ]
      ++ (lib.imap0 (idx: _: "x-systemd.requires=/mnt/disk${toString (idx + 1)}") vars.dataDisks)
      ++ (lib.imap0 (idx: _: "x-systemd.after=/mnt/disk${toString (idx + 1)}") vars.dataDisks);
  };

  systemd.tmpfiles.rules = [
    "d ${mergerfsMountPoint} 0755 root root -"
    "d /var/lib/snapraid 0750 root root -"
  ];

  environment.etc."snapraid.conf".text = ''
    parity /mnt/parity/snapraid.parity
    ${builtins.concatStringsSep "\n" (map (path: "content ${path}") snapraidContentFiles)}
    ${builtins.concatStringsSep "\n" (lib.imap0 mkSnapraidLine vars.dataDisks)}
    exclude *.unrecoverable
    exclude /appdata/
    exclude /*.bak-*/
    exclude /tmp/
    exclude lost+found/
  '';

  systemd.timers.snapraid-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = snapraidSyncTimer;
      Persistent = true;
    };
  };

  systemd.timers.snapraid-scrub = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = snapraidScrubTimer;
      Persistent = true;
    };
  };

  systemd.services.snapraid-sync = {
    description = "Sync SnapRAID arrays";
    unitConfig.RequiresMountsFor = snapraidMounts;
    path = [ pkgs.snapraid ];
    script = "snapraid sync";
    serviceConfig.Type = "oneshot";
  };

  systemd.services.snapraid-scrub = {
    description = "Scrub SnapRAID arrays";
    unitConfig.RequiresMountsFor = snapraidMounts;
    path = [ pkgs.snapraid ];
    script = "snapraid scrub -p 1 -o 10";
    serviceConfig.Type = "oneshot";
  };

  services.smartd = {
    enable = true;
    devices = map (id: { device = "/dev/disk/by-id/${id}"; })
      (vars.dataDisks ++ [ vars.parityDisk ]);
  };
}
