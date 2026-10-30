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

    privateStateRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/browsertrix-downloader-private-v2";
      description = "Private versioned state, untouched by the legacy rollback closure.";
    };

    legacyStateDir = lib.mkOption {
      type = lib.types.str;
      default = "${paths.stateRoot}/state";
      description = "Retained legacy SQLite directory; never expanded or restored automatically.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "${paths.privateStateRoot}/state";
      description = "Browsertrix Downloader SQLite state directory.";
    };

    workerHome = lib.mkOption {
      type = lib.types.str;
      default = "${paths.privateStateRoot}/worker";
      description = "Persistent home and rootless Podman storage for the crawler worker.";
    };

    cacheRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/browsertrix-downloader-private-v2";
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

    privateArchiveRoot = lib.mkOption {
      type = lib.types.str;
      default = "${vars.dataRoot}/browsertrix-downloader/private-archives";
      description = "Private data-pool WACZ payloads, outside shared library consumers.";
    };

    checkpointsRoot = lib.mkOption {
      type = lib.types.str;
      default = "${paths.privateStateRoot}/checkpoints";
      description = "Persistent worker checkpoints and WARC data for resumable captures.";
    };

    profilesRoot = lib.mkOption {
      type = lib.types.str;
      default = "${paths.privateStateRoot}/profiles";
      description = "Worker-only immutable browser profile material.";
    };

    inboxRoot = lib.mkOption {
      type = lib.types.str;
      default = "${paths.stateDir}/inbox";
      description = "Bounded upload staging shared only by the archive API and worker.";
    };
  };

  config = {
    assertions = [
      {
        assertion = paths.privateStateRoot != paths.legacyStateDir
          && paths.privateStateRoot != paths.stateRoot
          && !(lib.hasPrefix "${paths.stateRoot}/" paths.privateStateRoot)
          && lib.all (path: lib.hasPrefix "${paths.privateStateRoot}/" path) [
            paths.stateDir paths.workerHome paths.checkpointsRoot paths.profilesRoot paths.inboxRoot
          ];
        message = "Browsertrix private state must stay below its separate privateStateRoot for complete-closure rollback safety.";
      }
      {
        assertion = lib.all
          (path: path != paths.archiveRoot && !(lib.hasPrefix "${paths.archiveRoot}/" path))
          [ paths.privateStateRoot paths.privateArchiveRoot paths.cacheRoot ];
        message = "Browsertrix private state, scratch and payloads must remain outside the shared archive tree.";
      }
    ];
    repo.storage.sharedRoots.contentSubdirs = [ "_WebArchives" ];
    repo.storage.dataPool.guardedServices = [
      "browsertrix-downloader-storage-layout-v1"
      "browsertrix-downloader"
      "browsertrix-downloader-worker"
    ];

    systemd.tmpfiles.rules = [
      "d ${paths.stateRoot} 0770 browsertrix-downloader browsertrix-downloader -"
      "d ${paths.privateStateRoot} 0770 browsertrix-downloader browsertrix-private -"
      "d ${paths.stateDir} 0770 browsertrix-downloader browsertrix-private -"
      "d ${paths.workerHome} 0750 browsertrix-downloader-worker browsertrix-private -"
      "d ${paths.cacheRoot} 0750 browsertrix-downloader-worker browsertrix-private -"
      "d ${paths.crawlsRoot} 0750 browsertrix-downloader-worker browsertrix-private -"
      "d ${paths.checkpointsRoot} 0750 browsertrix-downloader-worker browsertrix-private -"
      "d ${paths.profilesRoot} 0700 browsertrix-downloader-worker browsertrix-private -"
      "d ${paths.inboxRoot} 0770 browsertrix-downloader browsertrix-private -"
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
        paths.privateStateRoot
        paths.archiveRoot
        paths.privateArchiveRoot
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.acl pkgs.coreutils pkgs.systemd ];
      script = ''
        set -euo pipefail

        # The copy is a handoff, never a live fork of two writers. Required
        # services wait for this unit; a manual restart while they run refuses.
        for unit in browsertrix-downloader browsertrix-downloader-worker; do
          if systemctl is-active --quiet "$unit.service"; then
            echo "Stop $unit.service before provisioning private state" >&2
            exit 1
          fi
        done

        install -d -m 0770 -o browsertrix-downloader -g browsertrix-downloader ${lib.escapeShellArg paths.stateRoot}
        for directory in ${lib.escapeShellArgs [ paths.privateStateRoot paths.stateDir paths.cacheRoot ]}; do
          if [[ -L "$directory" ]]; then
            echo "Refusing private state directory symlink: $directory" >&2
            exit 1
          fi
          install -d -m 0770 -o browsertrix-downloader -g browsertrix-private "$directory"
          setfacl -b -k "$directory"
          chmod 0770 "$directory"
        done
        install -d -m 0750 -o browsertrix-downloader-worker -g browsertrix-private ${lib.escapeShellArg paths.workerHome}
        install -d -m 0750 -o browsertrix-downloader-worker -g browsertrix-private ${lib.escapeShellArg paths.cacheRoot}
        install -d -m 0750 -o browsertrix-downloader-worker -g browsertrix-private ${lib.escapeShellArg paths.crawlsRoot}
        install -d -m 0750 -o browsertrix-downloader-worker -g browsertrix-private ${lib.escapeShellArg paths.checkpointsRoot}
        install -d -m 0700 -o browsertrix-downloader-worker -g browsertrix-private ${lib.escapeShellArg paths.profilesRoot}
        install -d -m 0770 -o browsertrix-downloader -g browsertrix-private ${lib.escapeShellArg paths.inboxRoot}

        # Private captures never inherit the shared library's default ACLs.
        if [[ -L ${lib.escapeShellArg paths.privateArchiveRoot} ]]; then
          echo "Refusing private archive directory symlink" >&2
          exit 1
        fi
        install -d -m 0750 -o browsertrix-downloader-worker -g browsertrix-private ${lib.escapeShellArg paths.privateArchiveRoot}
        setfacl -b -k ${lib.escapeShellArg paths.privateArchiveRoot}
        chmod 0750 ${lib.escapeShellArg paths.privateArchiveRoot}

        database_path=${lib.escapeShellArg "${paths.stateDir}/browsertrix-downloader.sqlite"}
        ${pkgs.python3}/bin/python3 ${./migrate-state.py} \
          ${lib.escapeShellArg "${paths.legacyStateDir}/browsertrix-downloader.sqlite"} "$database_path"
        find ${lib.escapeShellArg paths.stateDir} -xdev -maxdepth 1 -type f -name 'browsertrix-downloader.sqlite*' \
          -exec chown --no-dereference browsertrix-downloader:browsertrix-private {} +
        find ${lib.escapeShellArg paths.stateDir} -xdev -maxdepth 1 -type f -name 'browsertrix-downloader.sqlite*' \
          -exec chmod 0660 {} +

        install -d -m 0770 -o browsertrix-downloader-worker -g ${lib.escapeShellArg sharedAccessGroup} ${lib.escapeShellArg paths.archiveRoot}
        setfacl -m ${lib.escapeShellArg "g:${sharedAccessGroup}:rwx,d:g:${sharedAccessGroup}:rwx"} ${lib.escapeShellArg paths.archiveRoot}
      '';
    };
  };
}
