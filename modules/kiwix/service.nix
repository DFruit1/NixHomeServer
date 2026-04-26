{ config, lib, pkgs, vars, ... }:

let
  cfg = config.services.kiwixServe;
  kiwixStateDirDefault = "/var/lib/kiwix";
  kiwixPort = 8081;
  libraryFile = "${cfg.stateDir}/library.xml";
  prepareLibraryRootScript = pkgs.writeShellScript "kiwix-prepare-library-root" ''
    set -euo pipefail

    library_root=${lib.escapeShellArg cfg.libraryRoot}
    upload_user=${lib.escapeShellArg cfg.uploadUser}

    ${pkgs.coreutils}/bin/install -d -m 0750 -o root -g kiwix "$library_root"
    ${pkgs.acl}/bin/setfacl \
      -m "u:$upload_user:rwx" \
      -m g:kiwix:rx \
      -m "d:u:$upload_user:rwx" \
      -m d:g:kiwix:rx \
      "$library_root"
  '';
  syncLibraryScript = pkgs.writeShellScript "kiwix-sync-library" ''
    set -euo pipefail

    library_root=${lib.escapeShellArg cfg.libraryRoot}
    library_file=${lib.escapeShellArg libraryFile}
    upload_user=${lib.escapeShellArg cfg.uploadUser}
    tmp_library="$(mktemp)"
    trap 'rm -f "$tmp_library"' EXIT

    ${prepareLibraryRootScript}

    cat >"$tmp_library" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<library version="20110515"></library>
EOF

    while IFS= read -r -d $'\0' zim_path; do
      ${pkgs.acl}/bin/setfacl \
        -m "u:$upload_user:rw" \
        -m g:kiwix:r \
        "$zim_path"

      if ! ${cfg.package}/bin/kiwix-manage "$tmp_library" add "$zim_path"; then
        echo "Skipping invalid or incomplete ZIM file: $zim_path" >&2
      fi
    done < <(
      ${pkgs.findutils}/bin/find "$library_root" -maxdepth 1 -type f -name '*.zim' -print0 \
        | ${pkgs.coreutils}/bin/sort -z
    )

    ${pkgs.coreutils}/bin/install -D -m 0640 -o kiwix -g kiwix "$tmp_library" "$library_file"
  '';
in
{
  options.services.kiwixServe = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to run the internal Kiwix server.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.kiwix-tools;
      description = "Package providing kiwix-serve and kiwix-manage.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the Kiwix server listens on.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = kiwixPort;
      description = "Port the Kiwix server listens on.";
    };

    libraryRoot = lib.mkOption {
      type = lib.types.str;
      default = vars.kiwixLibraryRoot;
      description = "Directory containing uploaded ZIM files.";
    };

    uploadUser = lib.mkOption {
      type = lib.types.str;
      default =
        if builtins.hasAttr vars.kanidmAdminUser config.users.users then
          vars.kanidmAdminUser
        else if builtins.hasAttr "dsaw" config.users.users then
          "dsaw"
        else
          throw "services.kiwixServe.uploadUser must name a local Unix account.";
      description = ''
        Local Unix account allowed to upload ZIM files. This must be a
        machine account; the Kanidm principal alone is not sufficient.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = kiwixStateDirDefault;
      description = "Writable directory containing the generated Kiwix library catalog.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.kiwix = {
      isSystemUser = true;
      group = "kiwix";
      home = cfg.stateDir;
      createHome = false;
    };

    users.groups.kiwix = { };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 kiwix kiwix -"
    ];

    system.activationScripts.kiwixLibraryRoot = lib.stringAfter [ "users" "groups" ] ''
      ${prepareLibraryRootScript}
    '';

    systemd.services.kiwix-library-sync = {
      description = "Synchronize the generated Kiwix library catalog with uploaded ZIM files";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "kanidm.service"
        "data-pool-layout.service"
        "local-fs.target"
      ];
      after = [
        "kanidm.service"
        "data-pool-layout.service"
        "local-fs.target"
      ];
      before = [ "kiwix.service" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        ${syncLibraryScript}
      '';
    };

    systemd.timers.kiwix-library-sync = {
      description = "Periodically rescan uploaded ZIM files for Kiwix";
      wantedBy = [ "multi-user.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "30s";
        Unit = "kiwix-library-sync.service";
      };
    };

    systemd.services.kiwix = {
      description = "Kiwix offline content server";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "kiwix-library-sync.service"
        "network-online.target"
        "local-fs.target"
      ];
      after = [
        "kiwix-library-sync.service"
        "network-online.target"
        "local-fs.target"
      ];
      serviceConfig = {
        Type = "simple";
        User = "kiwix";
        Group = "kiwix";
        ExecStart = lib.concatStringsSep " " (map lib.escapeShellArg [
          "${cfg.package}/bin/kiwix-serve"
          "--library"
          libraryFile
          "--monitorLibrary"
          "--address=${cfg.address}"
          "--port=${toString cfg.port}"
        ]);
        Restart = "on-failure";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_NETLINK" "AF_UNIX" ];
        ReadOnlyPaths = [
          cfg.libraryRoot
          cfg.stateDir
        ];
      };
    };
  };
}
