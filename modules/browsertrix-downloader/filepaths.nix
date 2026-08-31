{ config, lib, pkgs, vars, ... }:

let
  paths = config.repo.browsertrixDownloader.paths;
  sharedAccessGroup = vars.fileAccess.sharedAccessGroup or "files-shared-users";
in
{
  options.repo.browsertrixDownloader.paths = {
    stateRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/browsertrix-downloader";
      description = "Persistent Browsertrix Downloader state root.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "${paths.stateRoot}/state";
      description = "Browsertrix Downloader SQLite state directory.";
    };

    workerHome = lib.mkOption {
      type = lib.types.str;
      default = "${paths.stateRoot}/worker";
      description = "Persistent home and rootless Podman storage for the crawler worker.";
    };

    cacheRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/browsertrix-downloader";
      description = "Non-persistent Browsertrix crawl scratch root.";
    };

    crawlsRoot = lib.mkOption {
      type = lib.types.str;
      default = "${paths.cacheRoot}/crawls";
      description = "Per-job Browsertrix crawl scratch directory.";
    };

    archiveRoot = lib.mkOption {
      type = lib.types.str;
      default = "${vars.sharedRoot}/_WebArchives";
      description = "Data-pool-backed WACZ archive root.";
    };
  };

  config = {
    repo.storage.sharedRoots.contentSubdirs = [ "_WebArchives" ];
    repo.storage.dataPool.guardedServices = [
      "browsertrix-downloader-storage-layout-v1"
      "browsertrix-downloader"
      "browsertrix-downloader-worker"
    ];

    systemd.tmpfiles.rules = [
      "d ${paths.stateRoot} 0770 browsertrix-downloader browsertrix-downloader -"
      "d ${paths.stateDir} 0770 browsertrix-downloader browsertrix-downloader -"
      "d ${paths.workerHome} 0750 browsertrix-downloader-worker browsertrix-downloader -"
      "d ${paths.cacheRoot} 0750 browsertrix-downloader-worker browsertrix-downloader -"
      "d ${paths.crawlsRoot} 0750 browsertrix-downloader-worker browsertrix-downloader -"
    ];

    systemd.services.browsertrix-downloader-storage-layout-v1 = {
      description = "Provision Browsertrix Downloader archive storage";
      wantedBy = [ "multi-user.target" ];
      wants = [ "data-pool-layout.service" ];
      after = [ "data-pool-layout.service" ];
      before = [
        "browsertrix-downloader.service"
        "browsertrix-downloader-worker.service"
      ];
      unitConfig.RequiresMountsFor = [
        paths.stateRoot
        paths.archiveRoot
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.acl pkgs.coreutils ];
      script = ''
        set -euo pipefail

        install -d -m 0770 -o browsertrix-downloader -g browsertrix-downloader ${lib.escapeShellArg paths.stateRoot}
        install -d -m 0770 -o browsertrix-downloader -g browsertrix-downloader ${lib.escapeShellArg paths.stateDir}
        install -d -m 0750 -o browsertrix-downloader-worker -g browsertrix-downloader ${lib.escapeShellArg paths.workerHome}
        install -d -m 0750 -o browsertrix-downloader-worker -g browsertrix-downloader ${lib.escapeShellArg paths.cacheRoot}
        install -d -m 0750 -o browsertrix-downloader-worker -g browsertrix-downloader ${lib.escapeShellArg paths.crawlsRoot}

        database_path=${lib.escapeShellArg "${paths.stateDir}/browsertrix-downloader.sqlite"}
        if [[ -L "$database_path" ]]; then
          echo "Refusing Browsertrix SQLite database symlink: $database_path" >&2
          exit 1
        fi
        if [[ ! -e "$database_path" ]]; then
          install -m 0660 -o browsertrix-downloader -g browsertrix-downloader /dev/null "$database_path"
        fi
        if [[ ! -f "$database_path" ]]; then
          echo "Browsertrix SQLite database is not a regular file: $database_path" >&2
          exit 1
        fi
        find ${lib.escapeShellArg paths.stateDir} -xdev -maxdepth 1 -type f -name 'browsertrix-downloader.sqlite*' \
          -exec chown --no-dereference browsertrix-downloader:browsertrix-downloader {} +
        find ${lib.escapeShellArg paths.stateDir} -xdev -maxdepth 1 -type f -name 'browsertrix-downloader.sqlite*' \
          -exec chmod 0660 {} +

        install -d -m 0770 -o browsertrix-downloader-worker -g ${lib.escapeShellArg sharedAccessGroup} ${lib.escapeShellArg paths.archiveRoot}
        setfacl -m ${lib.escapeShellArg "g:${sharedAccessGroup}:rwx,d:g:${sharedAccessGroup}:rwx"} ${lib.escapeShellArg paths.archiveRoot}
      '';
    };
  };
}
