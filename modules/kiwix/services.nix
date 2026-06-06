{ config, lib, pkgs, vars, ... }:

let
  cfg = config.services.kiwixServe;
  kiwixStateDirDefault = "/var/lib/kiwix";
  kiwixPort = vars.networking.ports.kiwix;
  libraryFile = "${cfg.stateDir}/library.xml";
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
in
{
  imports = [
    ./oauth2-proxy.nix
  ];

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
      default = config.repo.kiwix.paths.libraryRoot;
      description = "Directory containing uploaded ZIM files.";
    };

    uploadUser = lib.mkOption {
      type = lib.types.str;
      default =
        if builtins.hasAttr vars.localAdminUser config.users.users then
          vars.localAdminUser
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

  options.repo.kiwix.paths.libraryRoot = lib.mkOption {
    type = lib.types.str;
    default = "${vars.dataRoot}/kiwix";
    description = "Kiwix uploaded ZIM library root.";
  };

  config = lib.mkIf cfg.enable {
    services.kiwix-serve = {
      enable = true;
      package = cfg.package;
      address = cfg.address;
      port = cfg.port;
      libraryPath = libraryFile;
      extraArgs = [ "--monitorLibrary" ];
    };

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
      before = [ "kiwix-serve.service" ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        ${syncLibraryScript}
      '';
    };

    systemd.services.kiwix-serve = {
      wants = [
        "kiwix-library-sync.service"
        "local-fs.target"
      ];
      after = [
        "kiwix-library-sync.service"
        "local-fs.target"
      ];
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "kiwix";
        Group = "kiwix";
        ReadOnlyPaths = [
          cfg.libraryRoot
          cfg.stateDir
        ];
      };
    };
  };
}
