{ config, lib, options, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  kiwixArchivesPort = vars.networking.ports.kiwixArchives;
  zimReaderUrlPath = "/zim";
in
{
  config = lib.mkIf
    (
      lib.hasAttrByPath [ "repo" "browsertrixDownloader" ] options
      && lib.hasAttrByPath [ "repo" "kiwix" ] options
      && config.repo.kiwix.enable
    )
    {
      repo.storage.dataPool.guardedServices = [ "kiwix-serve-archives" ];

      systemd.services.browsertrix-downloader = {
        environment = {
          BROWSERTRIX_DOWNLOADER_ZIM_ROOT = config.repo.kiwix.paths.libraryRoot;
          BROWSERTRIX_DOWNLOADER_ZIM_READER_URL = "${zimReaderUrlPath}/";
        };
        serviceConfig = {
          SupplementaryGroups = lib.mkAfter [ "kiwix" ];
          ReadOnlyPaths = lib.mkAfter [ config.repo.kiwix.paths.libraryRoot ];
        };
      };

      systemd.services.kiwix-serve-archives = {
        description = "Kiwix reader for the Web Archives application";
        wantedBy = [ "multi-user.target" ];
        wants = [
          "kiwix-library-sync.service"
          "local-fs.target"
        ];
        after = [
          "kiwix-library-sync.service"
          "local-fs.target"
        ];
        unitConfig.RequiresMountsFor = [ config.repo.kiwix.paths.libraryRoot ];
        serviceConfig = {
          Type = "simple";
          User = "kiwix";
          Group = "kiwix";
          ExecStart = lib.concatStringsSep " " (map lib.escapeShellArg [
            "${config.repo.kiwix.package}/bin/kiwix-serve"
            "--library=${config.services.kiwix-serve.libraryPath}"
            "--address=${loopback}"
            "--port=${toString kiwixArchivesPort}"
            "--urlRootLocation=${zimReaderUrlPath}"
            "--monitorLibrary"
          ]);
          Restart = "on-failure";
          RestartSec = "5s";
          UMask = "0007";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          LockPersonality = true;
          RestrictSUIDSGID = true;
          RestrictNamespaces = true;
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          SystemCallArchitectures = "native";
          ReadOnlyPaths = [
            config.repo.kiwix.paths.libraryRoot
            config.repo.kiwix.stateDir
          ];
        };
      };

      repo.authGateway.protectedApps.browsertrix.authenticatedRoutes = [
        {
          pathPrefix = zimReaderUrlPath;
          upstream = "http://${loopback}:${toString kiwixArchivesPort}";
        }
      ];
    };
}
