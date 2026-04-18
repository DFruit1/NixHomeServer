# modules/apparmor/apparmor-autogen.nix
{ lib, pkgs, config, profilesDir ? ../../apparmor-auto/out/profiles, ... }:
let
  inherit (lib) mkIf mkMerge mapAttrs' nameValuePair;
  generated = builtins.attrNames (builtins.readDir profilesDir);
  etcEntries = map (name: let p = "${profilesDir}/${name}"; in {
    target = "/etc/apparmor.d/auto-${name}";
    source = p;
    mode = "0444";
  }) generated;
in
{
  security.apparmor.enable = true;

  environment.etc = lib.listToAttrs (map (e: nameValuePair e.target { inherit (e) source mode; }) etcEntries);

  systemd.services.apparmor-reload = {
    description = "Reload AppArmor after profile updates";
    wantedBy = [ "multi-user.target" ];
    after = [ "apparmor.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "aa-reload" ''
        set -euo pipefail
        if command -v apparmor_parser >/dev/null; then
          for f in /etc/apparmor.d/auto-*.profile; do
            [ -f "$f" ] || continue
            ${pkgs.apparmor-utils}/bin/apparmor_parser -r "$f"
          done
        fi
      '';
    };
  };
}
