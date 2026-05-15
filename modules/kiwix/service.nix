{ config, lib, pkgs, vars, ... }:

let
  cfg = config.services.kiwixServe;
  libraryWatchers = import ../Core_Modules/library-watchers.nix { inherit pkgs; };
  kiwixStateDirDefault = "/var/lib/kiwix";
  kiwixPort = vars.networking.ports.kiwix;
  libraryFile = "${cfg.stateDir}/library.xml";
  uploadUsers = lib.unique ([ cfg.uploadUser ] ++ cfg.extraUploadUsers);
  dirWriterAclArgs = lib.concatStringsSep " " (
    lib.concatMap
      (user: [
        ''-m u:${user}:rwx''
        ''-m d:u:${user}:rwx''
      ])
      uploadUsers
  );
  prepareLibraryRootScript = pkgs.writeShellScript "kiwix-prepare-library-root" ''
    set -euo pipefail

    library_root=${lib.escapeShellArg cfg.libraryRoot}

    if [[ ! -d "$library_root" ]]; then
      ${pkgs.coreutils}/bin/install -d -m 0750 -o root -g kiwix "$library_root"
    fi
    ${pkgs.acl}/bin/setfacl \
      ${dirWriterAclArgs} \
      -m g:kiwix:rx \
      -m d:g:kiwix:rx \
      "$library_root"
  '';
  syncLibraryScript = pkgs.writeShellScript "kiwix-sync-library" ''
        set -euo pipefail

        library_root=${lib.escapeShellArg cfg.libraryRoot}
        library_file=${lib.escapeShellArg libraryFile}
        state_dir=${lib.escapeShellArg cfg.stateDir}
        tmp_library="$(${pkgs.coreutils}/bin/mktemp "$state_dir/library.XXXXXX.xml")"
        trap 'rm -f "$tmp_library"' EXIT

        cat >"$tmp_library" <<'EOF'
    <?xml version="1.0" encoding="UTF-8"?>
    <library version="20110515"></library>
    EOF

        while IFS= read -r -d $'\0' zim_path; do
          if ! ${cfg.package}/bin/kiwix-manage "$tmp_library" add "$zim_path"; then
            echo "Skipping invalid or incomplete ZIM file: $zim_path" >&2
          fi
        done < <(
          ${pkgs.findutils}/bin/find "$library_root" -maxdepth 1 -type f -name '*.zim' -print0 \
            | ${pkgs.coreutils}/bin/sort -z
        )

        ${pkgs.coreutils}/bin/install -D -m 0640 -o kiwix -g kiwix "$tmp_library" "$library_file"
  '';
  watcherScript = libraryWatchers.mkSettledWatcherScript {
    name = "kiwix-library-watch";
    watchedRoots = [ cfg.libraryRoot ];
    triggerUnit = "kiwix-library-sync.service";
    settleSeconds = 20;
    pollSeconds = 5;
  };
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
      default = vars.networking.loopbackIPv4;
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

    extraUploadUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Additional local Unix accounts that need direct write access to the
        uploaded ZIM directory.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = kiwixStateDirDefault;
      description = "Writable directory containing the generated Kiwix library catalog.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = map
      (user: {
        assertion = builtins.hasAttr user config.users.users;
        message = "services.kiwixServe.extraUploadUsers entry '${user}' must name a local Unix account.";
      })
      cfg.extraUploadUsers;

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

    systemd.services.kiwix-library-watch = {
      description = "Watch ZIM uploads and debounce Kiwix catalog sync";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "kiwix-library-sync.service"
        "local-fs.target"
      ];
      after = [
        "kiwix-library-sync.service"
        "local-fs.target"
      ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${watcherScript}";
        Restart = "always";
        RestartSec = "5s";
      };
    };
  };
}
