{
  description = "Full fledged home server …";
  nixConfig.extra-experimental-features = [ "nix-command" "flakes" ];

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    crane.url = "github:ipetkov/crane";
    agenix.url = "github:ryantm/agenix";
    disko.url = "github:nix-community/disko";
    impermanence.url = "github:nix-community/impermanence";
    impermanence.inputs.nixpkgs.follows = "nixpkgs";
    copyparty.url = "github:9001/copyparty";
    copyparty.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, crane, agenix, disko, impermanence, copyparty, ... }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      pkgsUnstable = nixpkgs-unstable.legacyPackages.${system};
      impermanencePatched = pkgs.applyPatches {
        name = "impermanence-patched";
        src = impermanence;
        patches = [
          ./patches/impermanence-nixpkgs-25-11-dir-method.patch
        ];
      };
      checkNativeBuildInputs = with pkgs; [
        bash
        coreutils
        findutils
        getent
        gnugrep
        gnused
        gnutar
        jq
        nix
        ripgrep
      ];
      vars = import ./vars.nix { inherit lib; };
      nixosHost = lib.nixosSystem {
        inherit system;
        modules = [
          ./hardware-configuration.nix
          ./configuration.nix
          agenix.nixosModules.default
          disko.nixosModules.disko
          (impermanencePatched + "/nixos.nix")
        ];
        specialArgs = {
          inherit self vars disko copyparty pkgsUnstable;
        };
      };
      coreConfigSnapshotFile =
        let
          cfg = nixosHost.config;
          snapshot = {
            vars = {
              serverLanGateway = vars.serverLanGateway;
              serverLanIP = vars.serverLanIP;
              serverLanPrefixLength = vars.serverLanPrefixLength;
              dataRoot = vars.dataRoot;
              netIface = vars.netIface;
              photosDomain = vars.photosDomain;
              sharePhotosDomain = vars.sharePhotosDomain;
              uploadsDomain = vars.uploadsDomain;
              filebrowserDomain = vars.filebrowserDomain;
              vaultwardenDomain = vars.vaultwardenDomain;
              monitorDomain = vars.monitorDomain;
              runtimeAccessCanaries = vars.runtimeAccessCanaries;
              personalKavitaLibraries = vars.personalKavitaLibraries;
              sharedBooksSubdirs = vars.sharedBooksSubdirs;
            };
            config = {
              services = {
                caddyEnable = cfg.services.caddy.enable;
                cloudflaredEnable = cfg.services.cloudflared.enable;
                unboundEnable = cfg.services.unbound.enable;
                kanidmEnableServer = cfg.services.kanidm.enableServer;
                netbirdAutostart = cfg.services.netbird.clients.myNetbirdClient.autoStart;
              };
              networking = {
                gatewayAddress = cfg.networking.defaultGateway.address;
                lanUseDhcp = cfg.networking.interfaces.${vars.netIface}.useDHCP;
                lanAddresses = cfg.networking.interfaces.${vars.netIface}.ipv4.addresses;
                lanAllowedTcpPorts = cfg.networking.firewall.interfaces.${vars.netIface}.allowedTCPPorts;
                lanAllowedUdpPorts = cfg.networking.firewall.interfaces.${vars.netIface}.allowedUDPPorts;
                nameservers = cfg.networking.nameservers;
              };
              fileSystems = {
                hasDataMount = cfg.fileSystems ? "/mnt/data";
                dataFsType = if cfg.fileSystems ? "/mnt/data" then cfg.fileSystems."/mnt/data".fsType else null;
                persistNeededForBoot = cfg.fileSystems."/persist".neededForBoot;
                nixNeededForBoot = cfg.fileSystems."/nix".neededForBoot;
                hasLegacyWorkspacesMount = cfg.fileSystems ? "/mnt/data/workspaces";
                hasLegacyMailArchiveMount = cfg.fileSystems ? "/mnt/data/mail-archive";
              };
              restic = {
                repository = cfg.services.restic.backups.system-state.repository;
                pathCount = builtins.length cfg.services.restic.backups.system-state.paths;
              };
              monitoring = {
                hasSystemHealthService = cfg.systemd.services ? "system-health-report";
                hasSystemHealthTimer = cfg.systemd.timers ? "system-health-report";
                hasStorageSmartShortService = cfg.systemd.services ? "storage-smart-short";
                hasStorageSmartLongService = cfg.systemd.services ? "storage-smart-long";
                hasStorageSmartShortTimer = cfg.systemd.timers ? "storage-smart-short";
                hasStorageSmartLongTimer = cfg.systemd.timers ? "storage-smart-long";
                hasSmartdService = cfg.systemd.services ? "smartd";
                systemHealthReportPath =
                  map (package: lib.getName package) (cfg.systemd.services."system-health-report".path or [ ]);
              };
              storage = {
                zfsImportScript = cfg.systemd.services.zfs-import-data.script;
              };
              apps = {
                caddyHostNames = builtins.attrNames cfg.services.caddy.virtualHosts;
                caddyHostCount = builtins.length (builtins.attrNames cfg.services.caddy.virtualHosts);
                cloudflaredIngressHostNames = builtins.attrNames cfg.services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress;
                cloudflaredIngressCount = builtins.length (builtins.attrNames cfg.services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress);
                oauthSystemNames = builtins.attrNames cfg.services.kanidm.provision.systems.oauth2;
                provisionGroupNames = builtins.attrNames cfg.services.kanidm.provision.groups;
                provisionPersonNames = builtins.attrNames cfg.services.kanidm.provision.persons;
                provisionPersons = cfg.services.kanidm.provision.persons;
                ageSecretNames = builtins.attrNames cfg.age.secrets;
                mailArchiveUiEnable = cfg.services.mail-archive-ui.enable;
                mailArchiveVisibleMirrorReadGroup = cfg.services.mail-archive-ui.visibleMirrorReadGroup;
                hasMailArchiveOauth2ProxyService = cfg.systemd.services ? "mail-archive-oauth2-proxy";
                mailArchiveOauth2ProxyExecStartPre =
                  cfg.systemd.services."mail-archive-oauth2-proxy".serviceConfig.ExecStartPre or [ ];
                mailArchiveUiMountCondition =
                  cfg.systemd.services."mail-archive-ui".unitConfig.ConditionPathIsMountPoint or null;
                mailArchiveUiPath =
                  map (package: lib.getName package) (cfg.systemd.services."mail-archive-ui".path or [ ]);
                mailArchiveSyncPath =
                  map (package: lib.getName package) (cfg.systemd.services."mail-archive-sync".path or [ ]);
                hasCopypartyService = cfg.systemd.services ? "copyparty";
                hasCopypartyRuntimeConfigSync = cfg.systemd.services ? "copyparty-runtime-config-sync";
                copypartyServiceSupplementaryGroups =
                  cfg.systemd.services.copyparty.serviceConfig.SupplementaryGroups or [ ];
                copypartyServiceBindPaths =
                  cfg.systemd.services.copyparty.serviceConfig.BindPaths or [ ];
                hasFilebrowserQuantumService = cfg.systemd.services ? "filebrowser-quantum";
                hasFilebrowserQuantumAccessSync = cfg.systemd.services ? "filebrowser-quantum-access-sync-v1";
                filebrowserQuantumExtraGroups = cfg.users.users.filebrowser-quantum.extraGroups or [ ];
                copypartySettings = cfg.services.copyparty.settings;
                copypartyVolumes = cfg.services.copyparty.volumes;
                copypartyPreStart = cfg.systemd.services.copyparty.preStart;
                usersGroupMembers = cfg.users.groups.users.members or [ ];
                hasImmichServerService = cfg.systemd.services ? "immich-server";
                hasPaperlessWebService = cfg.systemd.services ? "paperless-web";
                hasPaperlessPermissionsBootstrap = cfg.systemd.services ? "paperless-permissions-bootstrap";
                paperlessPermissionsBootstrapScript = cfg.systemd.services.paperless-permissions-bootstrap.script;
                paperlessSocialAccountSyncGroups = cfg.services.paperless.settings.PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS;
                paperlessSocialAccountSyncGroupsClaim = cfg.services.paperless.settings.PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS_CLAIM;
                hasOauth2ProxyService = cfg.systemd.services ? "oauth2-proxy";
                oauth2ProxyExecStart = cfg.systemd.services.oauth2-proxy.serviceConfig.ExecStart or "";
                hasAudiobookshelfLibrarySync = cfg.systemd.services ? "audiobookshelf-library-sync";
                hasAudiobookshelfLibrarySyncTimer = cfg.systemd.timers ? "audiobookshelf-library-sync";
                hasAudiobookshelfLibraryWatchConfig = cfg.systemd.services ? "audiobookshelf-library-watch-config-v1";
                audiobookshelfLibraryWatchConfigScript =
                  cfg.systemd.services."audiobookshelf-library-watch-config-v1".script or "";
                hasAudiobookshelfLibraryWatch = cfg.systemd.services ? "audiobookshelf-library-watch";
                hasKavitaLibrarySync = cfg.systemd.services ? "kavita-library-sync";
                hasKavitaLibrarySyncTimer = cfg.systemd.timers ? "kavita-library-sync";
                hasKavitaMediaAclSync = cfg.systemd.services ? "kavita-media-acl-sync-v1";
                hasKavitaLibraryWatch = cfg.systemd.services ? "kavita-library-watch";
                hasKiwixLibraryWatch = cfg.systemd.services ? "kiwix-library-watch";
                hasLegacyKiwixLibraryTimer = cfg.systemd.timers ? "kiwix-library-sync";
                hasJellyfinLibraryMonitor = cfg.systemd.services ? "jellyfin-library-monitor-v1";
                hasJellyfinLibrarySync = cfg.systemd.services ? "jellyfin-library-sync";
                jellyfinLibrarySyncAfter = cfg.systemd.services.jellyfin-library-sync.after;
                jellyfinLibrarySyncWants = cfg.systemd.services.jellyfin-library-sync.wants;
                hasJellyfinLibraryWatch = cfg.systemd.services ? "jellyfin-library-watch";
                hasGlancesService = cfg.systemd.services ? "glances";
                hasGlancesOauth2ProxyService = cfg.systemd.services ? "glances-oauth2-proxy";
                hasVaultwardenService = cfg.systemd.services ? "vaultwarden";
              };
            };
          };
        in
        pkgs.writeText "core-config-snapshot.json" (builtins.toJSON snapshot);
      rustLib = import ./rust/lib { inherit lib pkgs crane; };
      rustApps = import ./rust/apps { inherit lib pkgs rustLib; };
      rustPackages = lib.mapAttrs (_: app: app.package) rustApps;
      rustShells =
        {
          rust = rustLib.mkRustShell {
            name = "rust";
          };
          ops = pkgs.mkShell {
            name = "ops-dev-shell";
            packages = with pkgs; [
              deadnix
              gitMinimal
              jq
              nix-output-monitor
              nix-tree
              nixpkgs-fmt
              nvd
              python3
              ripgrep
              shellcheck
              statix
            ];
          };
        }
        // lib.mapAttrs (_: app: app.devShell) rustApps;
      rustChecks = lib.concatMapAttrs
        (name: app: {
          "${name}-fmt" = app.checks.fmt;
          "${name}-clippy" = app.checks.clippy;
          "${name}-test" = app.checks.test;
        })
        rustApps;
      rustFlakeApps = lib.mapAttrs
        (_: app: {
          type = "app";
          program = "${app.package}/bin/${app.binaryName}";
          meta = app.meta;
        })
        rustApps;
    in
    {
      ################ NixOS configuration ############################
      nixosConfigurations.${vars.hostname} = nixosHost;

      ################ Packages #######################################
      packages.${system} = rustPackages;

      ################ Formatter ######################################
      formatter.${system} = pkgs.nixpkgs-fmt;

      ################ Checks #########################################
      checks.${system} = {
        repo-policy = pkgs.runCommand "repo-policy"
          {
            nativeBuildInputs = checkNativeBuildInputs;
          } ''
          export HOME="$TMPDIR"
          export NIX_CONFIG="experimental-features = nix-command flakes"
          cd ${self}
          bash scripts/tests/test-secret-definitions.sh
          bash scripts/tests/test-deploy-with-validation-remote-preflight.sh
          bash scripts/tests/test-storage-health-checks.sh
          bash scripts/tests/test-runtime-readiness.sh
          bash scripts/tests/test-system-health-report.sh
          export CORE_CONFIG_SNAPSHOT_JSON="$(cat ${coreConfigSnapshotFile})"
          bash scripts/tests/test-evaluated-host-config.sh
          touch "$out"
        '';
      } // rustChecks;

      ################ Dev shells #####################################
      devShells.${system} = rustShells;

      ################ Extra helper app ###############################
      apps.${system} =
        {
          disko = {
            type = "app";
            program = "${disko.packages.${system}.disko}/bin/disko";
            meta = { description = "Disko CLI helper for blank-machine bootstrap only"; };
          };
        }
        // rustFlakeApps;
    };
}
