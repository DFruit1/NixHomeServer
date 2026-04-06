{ config, pkgs, lib, vars, inputs, ... }:

let
  mergerfsMountPoint = "/mnt/data";

  mergerfsSourceList =
    lib.concatStringsSep ":"
      (lib.imap0
        (idx: _: "/mnt/disk${toString (idx + 1)}")
        vars.dataDisks);

  mkSnapraidLine = idx: _:
    let n = toString (idx + 1); in "data d${n} /mnt/disk${n}";
in
{
  imports = [
    inputs.disko.nixosModules.disko
    ./disko.nix
  ];

  disko.enableConfig = true;

  environment.systemPackages = with pkgs; [ mergerfs snapraid smartmontools ];

  fileSystems = {
    "${mergerfsMountPoint}" = {
      fsType  = "fuse.mergerfs";
      device  = mergerfsSourceList;
      options = [
        "defaults" "allow_other" "use_ino"
        "minfreespace=10G" "category.create=epmfs"
      ];
    };
  };

  environment.etc."snapraid.conf".text = ''
    parity /mnt/parity/snapraid.parity
    ${builtins.concatStringsSep "\n" (lib.imap0 mkSnapraidLine vars.dataDisks)}
    exclude *.unrecoverable
    exclude /tmp/
    exclude lost+found/
  '';

  # timers
  systemd.timers.snapraid-sync  = { wantedBy = [ "timers.target" ]; timerConfig.OnCalendar = "daily";  timerConfig.Persistent = true; };
  systemd.timers.snapraid-scrub = { wantedBy = [ "timers.target" ]; timerConfig.OnCalendar = "weekly"; timerConfig.Persistent = true; };

  # services
  systemd.services.snapraid-sync = {
    description   = "Sync SnapRAID arrays";
    serviceConfig.Type = "oneshot";
    path          = [ pkgs.snapraid ];
    script        = "snapraid sync";
  };

  systemd.services.snapraid-scrub = {
    description   = "Scrub SnapRAID arrays";
    serviceConfig.Type = "oneshot";
    path          = [ pkgs.snapraid ];
    script        = "snapraid scrub -p 1 -o 10";
  };

  services.smartd = {
    enable = true;
    devices = map (id: { device = "/dev/disk/by-id/${id}"; })
              (vars.dataDisks ++ [ vars.parityDisk ]);
  };
}
