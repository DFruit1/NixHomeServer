{ config, lib, pkgs, vars, ... }:

let
  sharedKavitaDirs = map (library: "${vars.sharedBooksRoot}/${library.dir}") vars.sharedKavitaLibraries;
  sharedKavitaAnonDirs = map (library: "${vars.sharedBooksRoot}/${library.dir}/_Anon") vars.sharedKavitaLibraries;
in
{
  config = lib.mkIf config.nixhomeserver.apps.kavita.enable {
    users.groups.kavita-media = { };
    users.users.kavita.extraGroups = lib.mkAfter [ "kavita-media" ];

    systemd.services.kavita-storage-layout-v1 = {
      description = "Provision Kavita storage layout";
      wantedBy = [ "multi-user.target" ];
      wants = [ "data-pool-layout.service" "local-fs.target" ];
      after = [ "data-pool-layout.service" "local-fs.target" ];
      before = [ "kavita.service" ];
      unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [
        pkgs.acl
        pkgs.coreutils
        pkgs.findutils
      ];
      script = ''
        set -euo pipefail

        install -d -m 2775 -o root -g users ${vars.sharedBooksRoot}
        for path in ${lib.escapeShellArgs sharedKavitaDirs}; do
          install -d -m 2775 -o root -g users "$path"
        done
        for path in ${lib.escapeShellArgs sharedKavitaAnonDirs}; do
          install -d -m 2775 -o root -g users "$path"
        done

        apply_recursive_acl() {
          local access_spec="$1"
          local default_spec="$2"
          shift
          shift

          for path in "$@"; do
            [[ -d "$path" ]] || continue
            setfacl -R -m "$access_spec" "$path"
            find "$path" -type d -exec setfacl -m "$default_spec" '{}' +
          done
        }

        apply_recursive_acl "g:kavita-media:rwX" "d:g:kavita-media:rwx" ${lib.escapeShellArgs sharedKavitaDirs}
      '';
    };

    systemd.services.kavita = {
      wants = [
        "data-pool-layout.service"
        "kavita-storage-layout-v1.service"
      ];
      after = [
        "data-pool-layout.service"
        "kavita-storage-layout-v1.service"
      ];
    };
  };
}
