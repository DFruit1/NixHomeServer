{ lib, pkgs, vars, ... }:

let
  snapraidSyncTimer = "*-*-* 22:00:00";
  snapraidScrubTimer = "Sun *-*-* 10:00:00";
  mergerfsMountPoint = vars.dataRoot;
  dataMountPoint = idx: "/mnt/disk${toString (idx + 1)}";
  parityMountPoint = idx:
    if idx == 0 then
      "/mnt/parity"
    else
      "/mnt/parity${toString (idx + 1)}";
  parityDirectiveName = idx:
    if idx == 0 then
      "parity"
    else
      "${toString (idx + 1)}-parity";
  legacyAppStateDirs = [
    "audiobookshelf"
    "copyparty"
    "immich"
    "jellyfin"
    "kavita"
    "paperless"
  ];
  dataMounts = lib.imap0 (idx: _: dataMountPoint idx) vars.dataDisks;
  parityMounts = lib.imap0 (idx: _: parityMountPoint idx) vars.parityDisks;
  mkActiveMount = mount: diskId: lib.nameValuePair mount {
    device = lib.mkForce "/dev/disk/by-id/${diskId}-part1";
    options = lib.mkAfter activeArrayMountOptions;
  };
  dataMountDefs = lib.imap0 (idx: diskId: mkActiveMount (dataMountPoint idx) diskId) vars.dataDisks;
  parityMountDefs = lib.imap0 (idx: diskId: mkActiveMount (parityMountPoint idx) diskId) vars.parityDisks;
  snapraidContentFiles =
    [ "/var/lib/snapraid/snapraid.content" ]
    ++ map (mount: "${mount}/snapraid.content") dataMounts
    ++ map (mount: "${mount}/snapraid.content") parityMounts;
  mergerfsSourceList = lib.concatStringsSep ":" dataMounts;
  mkSnapraidLine = idx: _:
    let
      n = toString (idx + 1);
    in
    "data d${n} ${dataMountPoint idx}";
  mkParityLine = idx: _:
    let
      directive = parityDirectiveName idx;
    in
    "${directive} ${parityMountPoint idx}/snapraid.${directive}";
  snapraidMounts = [ mergerfsMountPoint ] ++ dataMounts ++ parityMounts;
  smartDevices =
    vars.dataDisks
    ++ vars.parityDisks
    ++ lib.optional (vars.enableBackupDisk && vars.backupDisk != null) vars.backupDisk;
  activeArrayMountOptions = [ "x-systemd.wanted-by=multi-user.target" ];
  activeLeafMounts = dataMounts ++ parityMounts;
in
{
  environment.systemPackages = with pkgs; [
    mergerfs
    snapraid
    smartmontools
  ];

  fileSystems =
    builtins.listToAttrs (dataMountDefs ++ parityMountDefs)
    // {
      ${mergerfsMountPoint} = {
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
          ++ activeArrayMountOptions
          ++ map (mount: "x-systemd.requires=${mount}") dataMounts
          ++ map (mount: "x-systemd.after=${mount}") dataMounts;
      };
    };

  systemd.tmpfiles.rules = [
    "d ${mergerfsMountPoint} 0755 root root -"
    "d /var/lib/snapraid 0750 root root -"
  ]
  ++ map (mount: "d ${mount} 0755 root root -") activeLeafMounts;

  environment.etc."snapraid.conf".text = ''
    ${builtins.concatStringsSep "\n" (lib.imap0 mkParityLine vars.parityDisks)}
    ${builtins.concatStringsSep "\n" (map (path: "content ${path}") snapraidContentFiles)}
    ${builtins.concatStringsSep "\n" (lib.imap0 mkSnapraidLine vars.dataDisks)}
    exclude *.unrecoverable
    exclude /appdata/
    ${builtins.concatStringsSep "\n" (map (dir: "exclude /${dir}/") legacyAppStateDirs)}
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
    devices = map (id: { device = "/dev/disk/by-id/${id}"; }) smartDevices;
  };
}
