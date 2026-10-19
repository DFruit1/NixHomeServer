{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.kiwix;
  kiwixStateDirDefault = "/var/lib/kiwix";
  kiwixPort = vars.networking.ports.kiwix;
  libraryFile = "${cfg.stateDir}/library.xml";
  syncLibraryScript = pkgs.writeShellScript "kiwix-sync-library" ''
        set -euo pipefail

        library_root=${lib.escapeShellArg cfg.paths.libraryRoot}
        library_file=${lib.escapeShellArg libraryFile}
        state_dir=${lib.escapeShellArg cfg.stateDir}
        tmp_manifest=""
        tmp_library=""
        cleanup() {
          if [ -n "$tmp_manifest" ]; then
            ${pkgs.coreutils}/bin/rm -f -- "$tmp_manifest"
          fi
          if [ -n "$tmp_library" ]; then
            ${pkgs.coreutils}/bin/rm -f -- "$tmp_library"
          fi
        }
        trap cleanup EXIT
        tmp_manifest="$(${pkgs.coreutils}/bin/mktemp "$state_dir/library-manifest.XXXXXX")"
        tmp_library="$(${pkgs.coreutils}/bin/mktemp "$state_dir/library.XXXXXX.xml")"

        cat >"$tmp_library" <<'EOF'
    <?xml version="1.0" encoding="UTF-8"?>
    <library version="20110515"></library>
    EOF

        if ! ${pkgs.findutils}/bin/find "$library_root" -maxdepth 1 -type f -name '*.zim' -print0 \
          | ${pkgs.coreutils}/bin/sort -z >"$tmp_manifest"; then
          echo "Failed to enumerate Kiwix library files; preserving the published catalog." >&2
          exit 1
        fi

        while IFS= read -r -d $'\0' zim_path; do
          if ! ${cfg.package}/bin/kiwix-manage "$tmp_library" add "$zim_path"; then
            echo "Skipping invalid or incomplete ZIM file: $zim_path" >&2
          fi
        done <"$tmp_manifest"

        ${pkgs.coreutils}/bin/chown kiwix:kiwix "$tmp_library"
        ${pkgs.coreutils}/bin/chmod 0640 "$tmp_library"
        ${pkgs.coreutils}/bin/mv -f -- "$tmp_library" "$library_file"
  '';
in
{
  imports = [
    ./oauth2-proxy.nix
  ];

  options.repo.kiwix = {
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

    paths.libraryRoot = lib.mkOption {
      type = lib.types.str;
      default = "${vars.dataRoot}/kiwix";
      description = "Directory containing uploaded ZIM files.";
    };

    uploadUser = lib.mkOption {
      type = lib.types.str;
      default =
        if builtins.hasAttr vars.localAdminUser config.users.users then
          vars.localAdminUser
        else
          throw "repo.kiwix.uploadUser must name a local Unix account.";
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
          cfg.paths.libraryRoot
          cfg.stateDir
        ];
      };
    };
  };
}
