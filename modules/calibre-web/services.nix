{ config, lib, vars, ... }:

let
  cfg = config.repo.calibreWeb;
  loopback = vars.networking.loopbackIPv4;
  calibreWebPort = vars.networking.ports.calibreWeb;
in
{
  options.repo.calibreWeb = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to run Calibre-Web for the shared technical library.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = calibreWebPort;
      description = "Loopback port Calibre-Web listens on.";
    };

    paths.libraryRoot = lib.mkOption {
      type = lib.types.str;
      default = "${vars.sharedRoot}/_Calibre/Library";
      description = ''
        Calibre library directory (a metadata.db plus author/book folders)
        served by Calibre-Web and indexed by the Search platform.
      '';
    };

    paths.stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/calibre-web";
      description = ''
        Calibre-Web application state directory holding app.db and local
        accounts. Persisted centrally; ownership is provisioned by the layout
        unit because this path is bind-mounted from /persist.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.calibre-web = {
      enable = true;
      listen = {
        ip = loopback;
        port = cfg.port;
      };
      dataDir = cfg.paths.stateDir;
      options = {
        calibreLibrary = cfg.paths.libraryRoot;
        # Books are added through the Calibre-Web UI or the documented
        # calibredb import path; both need the library to be writable.
        enableBookUploading = true;
        # Calibre-Web has no OIDC support. The shared auth gateway enforces
        # group membership, and Calibre-Web keeps its own local admin login for
        # uploads and library management.
        enableBookConversion = false;
        enableKepubify = false;
      };
    };
  };
}
