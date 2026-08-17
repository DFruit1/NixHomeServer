{ lib
, system
, vars
, paths
, mkvmakerPackage
}:

let
  sharedRoot = vars.sharedRoot;
  stateRoot = paths.stateRoot;
  configRoot = "/var/lib/mkvmaker-worker-config";
in
lib.nixosSystem {
  inherit system;
  modules = [
    ({ config, modulesPath, pkgs, ... }:
      let
        workerRunner = pkgs.writeShellApplication {
          name = "mkvmaker-worker-run";
          runtimeInputs = with pkgs; [
            coreutils
            gnugrep
            iproute2
            jq
            util-linux
            mkvmakerPackage
          ];
          text = ''
            config_file=${lib.escapeShellArg "${configRoot}/worker-config.json"}
            [[ -s "$config_file" ]] || {
              echo "Waiting for the server-published MKVMaker worker configuration: $config_file" >&2
              exit 1
            }
            jq -e \
              --arg state ${lib.escapeShellArg stateRoot} \
              --arg shared ${lib.escapeShellArg sharedRoot} '
                .schemaVersion == 2
                and .paths.stateRoot == $state
                and .paths.sharedRoot == $shared
                and .paths.inputDir == ${builtins.toJSON paths.dvdInbox}
                and .paths.moviesDir == ${builtins.toJSON paths.moviesOutput}
                and .paths.showsDir == ${builtins.toJSON paths.showsOutput}
                and .paths.stagingDir == ${builtins.toJSON paths.stagingRoot}
                and (.audioProfile | IN("standard", "compatible", "archive"))
                and (.videoPreset | IN("balanced", "compact", "maximum", "fast"))
                and (.settleSeconds | numbers and . >= 1)
                and (.minimumTitleSeconds | numbers and . >= 1)
                and (.dominantTitleRatio | numbers and . >= 0.5 and . <= 1.0)
                and (.metadataTimeoutSeconds | numbers and . >= 1)
                and (.maxAttempts | numbers and . >= 1)
                and (.retrySeconds | numbers and . >= 1)
                and (.leaseSeconds | numbers and . >= 30)
              ' "$config_file" >/dev/null || {
              echo "Server-published MKVMaker worker configuration is invalid" >&2
              exit 1
            }

            machine_identity=""
            if [[ -r /sys/class/dmi/id/product_uuid ]]; then
              machine_identity="$(tr -cd 'A-Fa-f0-9' </sys/class/dmi/id/product_uuid)"
            fi
            if [[ -z "$machine_identity" ]]; then
              for address_file in /sys/class/net/*/address; do
                [[ -r "$address_file" ]] || continue
                candidate="$(tr -cd 'A-Fa-f0-9' <"$address_file")"
                [[ "$candidate" != "000000000000" ]] || continue
                machine_identity="$candidate"
                break
              done
            fi
            [[ -n "$machine_identity" ]] || machine_identity="$(cat /proc/sys/kernel/random/uuid)"
            MKVMAKER_WORKER_ID="worker-$(printf '%s' "$machine_identity" | sha256sum | cut -c1-16)"
            export MKVMAKER_WORKER_ID

            input_dir="$(jq -er '.paths.inputDir' "$config_file")"
            movies_dir="$(jq -er '.paths.moviesDir' "$config_file")"
            shows_dir="$(jq -er '.paths.showsDir' "$config_file")"
            staging_dir="$(jq -er '.paths.stagingDir' "$config_file")"
            state_dir="$(jq -er '.paths.stateRoot + "/state"' "$config_file")"
            progress_dir="$(jq -er '.paths.stateRoot + "/progress"' "$config_file")"
            install -d -m 0770 "$progress_dir"

            exec mkvmaker-auto-import \
              --input-dir "$input_dir" \
              --movies-dir "$movies_dir" \
              --shows-dir "$shows_dir" \
              --state-dir "$state_dir" \
              --progress-file "$progress_dir/$MKVMAKER_WORKER_ID.json" \
              --staging-dir "$staging_dir" \
              --converter ${lib.escapeShellArg "${mkvmakerPackage}/bin/disc-to-jellyfin"} \
              --settle-seconds "$(jq -er '.settleSeconds' "$config_file")" \
              --min-duration "$(jq -er '.minimumTitleSeconds' "$config_file")" \
              --dominant-ratio "$(jq -er '.dominantTitleRatio' "$config_file")" \
              --metadata-timeout "$(jq -er '.metadataTimeoutSeconds' "$config_file")" \
              --max-attempts "$(jq -er '.maxAttempts' "$config_file")" \
              --retry-seconds "$(jq -er '.retrySeconds' "$config_file")" \
              --profile "$(jq -er '.audioProfile' "$config_file")" \
              --video-preset "$(jq -er '.videoPreset' "$config_file")" \
              --worker-id "$MKVMAKER_WORKER_ID" \
              --lease-seconds "$(jq -er '.leaseSeconds' "$config_file")"
          '';
        };
        ventoyCmdlineNormalizer = pkgs.writeShellApplication {
          name = "normalize-ventoy-kernel-cmdline";
          runtimeInputs = with pkgs; [
            coreutils
            gnused
          ];
          text = builtins.readFile ../scripts/helpers/normalize-ventoy-kernel-cmdline.sh;
        };
        mkRemoteFileSystem = path: {
          device = "${vars.serverLanIP}:${path}";
          fsType = "nfs";
          options = [
            "nfsvers=4.2"
            "_netdev"
            "nofail"
            "noauto"
            "x-systemd.automount"
            "x-systemd.idle-timeout=10min"
          ];
        };
        remoteFileSystems = {
          ${paths.dvdInbox} = mkRemoteFileSystem paths.dvdInbox;
          ${paths.moviesOutput} = mkRemoteFileSystem paths.moviesOutput;
          ${paths.showsOutput} = mkRemoteFileSystem paths.showsOutput;
          ${paths.stagingRoot} = mkRemoteFileSystem paths.stagingRoot;
          ${stateRoot} = mkRemoteFileSystem stateRoot;
          ${configRoot} = {
            device = "${vars.serverLanIP}:${configRoot}";
            fsType = "nfs";
            options = [
              "nfsvers=4.2"
              "ro"
              "_netdev"
              "nofail"
              "noauto"
              "x-systemd.automount"
              "x-systemd.idle-timeout=10min"
            ];
          };
        };
      in
      {
        # Official NixOS image interface:
        # https://nixos.org/manual/nixos/stable/#sec-building-image
        imports = [
          (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")
        ];

        nixpkgs.hostPlatform = system;
        networking.hostName = "mkvmaker-worker";
        networking.networkmanager.enable = true;
        networking.firewall.enable = true;
        hardware.enableRedistributableFirmware = true;
        boot.supportedFilesystems = [ "nfs" ];

        # Ventoy GRUB2 mode runs its own rdinit and renames the original
        # NixOS init= argument to vtinit=. Restore that spelling before the
        # upstream initrd closure-discovery service reads /proc/cmdline.
        boot.initrd.systemd.services.mkvmaker-ventoy-init-compat = {
          description = "Restore the NixOS init parameter after Ventoy GRUB2 handoff";
          before = [ "initrd-find-nixos-closure.service" ];
          requiredBy = [ "initrd-find-nixos-closure.service" ];
          unitConfig.DefaultDependencies = false;
          script = ''
            source_cmdline=/proc/cmdline
            normalized_cmdline="$(${ventoyCmdlineNormalizer}/bin/normalize-ventoy-kernel-cmdline < "$source_cmdline")"
            original_cmdline="$(< "$source_cmdline")"

            if [[ "$normalized_cmdline" == "$original_cmdline" ]]; then
              exit 0
            fi

            runtime_dir=/run/mkvmaker-ventoy-init-compat
            normalized_file="$runtime_dir/cmdline"
            ${pkgs.coreutils}/bin/mkdir -p "$runtime_dir"
            printf '%s\n' "$normalized_cmdline" > "$normalized_file"
            ${pkgs.util-linux}/bin/mount --bind "$normalized_file" "$source_cmdline"
          '';
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
        };

        users.groups.mkvmaker-worker = { };
        users.users.mkvmaker-worker = {
          isSystemUser = true;
          group = "mkvmaker-worker";
          description = "Unprivileged stateless MKVMaker conversion worker";
        };

        # The live-image module owns the root filesystem definition. Merge the
        # two remote automounts into that official ISO filesystem set.
        fileSystems = lib.mkForce (config.lib.isoFileSystems // remoteFileSystems);

        environment.systemPackages = with pkgs; [
          mkvmakerPackage
          nfs-utils
          workerRunner
        ];
        environment.etc."mkvmaker-worker/README".text = ''
          MKVMaker stateless worker

          1. Connect Ethernet, or run: nmtui
          2. Confirm the NixHomeServer is reachable at ${vars.serverLanIP}.
          3. Start now with: systemctl start mkvmaker-worker.service
          4. Follow progress with: journalctl -fu mkvmaker-worker.service

          This live system never mounts an internal disk automatically.
        '';

        isoImage.volumeID = "MKVMAKER_WORKER";

        systemd.timers.mkvmaker-worker = {
          description = "Regularly check the shared MKVMaker queue";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "30s";
            OnUnitInactiveSec = "1min";
            AccuracySec = "10s";
            Unit = "mkvmaker-worker.service";
          };
        };

        systemd.services.mkvmaker-worker = {
          description = "Claim and convert MKVMaker jobs from the NixHomeServer";
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          unitConfig.RequiresMountsFor = builtins.attrNames remoteFileSystems;
          environment = {
            HOME = stateRoot;
            XDG_CONFIG_HOME = "${stateRoot}/config";
            XDG_CACHE_HOME = "${stateRoot}/cache";
            XDG_STATE_HOME = "${stateRoot}/state";
          };
          serviceConfig = {
            Type = "simple";
            User = "mkvmaker-worker";
            Group = "mkvmaker-worker";
            ExecStart = "${workerRunner}/bin/mkvmaker-worker-run";
            Restart = "on-failure";
            RestartSec = "1min";
            TimeoutStartSec = "8h";
            TimeoutStopSec = "2min";
            KillSignal = "SIGINT";
            KillMode = "control-group";
            SendSIGKILL = true;
            FinalKillSignal = "SIGKILL";
            SuccessExitStatus = [ 130 "SIGINT" ];
            Nice = 10;
            CPUWeight = 50;
            IOWeight = 20;
            NoNewPrivileges = true;
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            CapabilityBoundingSet = "";
            AmbientCapabilities = "";
            RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
            ReadWritePaths = [
              paths.dvdInbox
              paths.moviesOutput
              paths.showsOutput
              paths.stagingRoot
              stateRoot
            ];
          };
        };

        system.stateVersion = "26.05";
      })
  ];
}
