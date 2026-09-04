{ lib, ... }:

let
  settings = {
    # ---------------------------------------------------------------------------
    # Start here: these sections are the normal operator-facing settings.
    # Most admins should be able to configure a new server by editing only this
    # first block, then running `nix run .#validate-config-readiness`.
    # ---------------------------------------------------------------------------

    branding = {
      displayName = "Home Server"; # Human-readable name shown in the portal and identity provider.
    };

    applications = {
      # Every application is opt-in. Add only catalog names that this host
      # should import, build, and test during routine validation.
      enabled = [
        "files"
        "homepage"
      ];
    };

    identity = {
      adminUser = "kanidm-admin"; # Dedicated Kanidm operator account; keep separate from the local Unix admin.
      appUsers = [ ]; # Extra existing Kanidm users granted default access to hosted apps.
      appAdminUsers = [ ]; # Extra app admins; they inherit normal app access and need not be repeated in appUsers.
      appUserEmails = { }; # Optional email map for extra app users, for example { alice = "alice@example.test"; }.
      adminEmail = "admin@example.test"; # Single contact address used for both ACME and the Kanidm admin account.
      sshPublicKey = "ssh-ed25519 CHANGE_ME example-admin-key"; # Public key authorized for the local Unix administrator.
      localAdminUser = "admin"; # Local Unix SSH/sudo account for bootstrap and operations.
      authSessionExpirySeconds = 259200; # Maximum Kanidm authentication-session lifetime in seconds (3 days).
    };

    network = {
      hostname = "example-server"; # NixOS hostname and flake hostname alias.
      domain = "example.test"; # Public DNS zone used for app hostnames.
      lanInterface = "eth0"; # Target server's wired LAN interface.
      lanIp = "192.0.2.10"; # Static LAN address for the server.
      lanPrefixLength = 24; # LAN CIDR prefix length; 24 is typical for home networks.
      lanGateway = "192.0.2.1"; # Router address on the same LAN subnet.
      netbirdIp = "100.64.0.10"; # Stable NetBird address assigned to this server.
      netbirdCidr = "100.64.0.0/10"; # NetBird network in canonical IPv4 CIDR form.
    };

    system = {
      hostPlatform = "x86_64-linux"; # Nix target platform. Supported values: "x86_64-linux" and "aarch64-linux".
      hardwareProfile = "generated"; # Hardware profile: "generated", "existing-server", or "generic-uefi".
      timeZone = "Etc/UTC"; # IANA time zone for timers, logs, and local maintenance windows.
      hostId = "00000000"; # Replace with a stable 8-character hexadecimal host ID for zfs-mirror.
      buildMode = "remote"; # Build allocation: "local", "remote", "balanced" (2 slots each with 1 requested core/job), or "maximum-effort" (all slots on both).
      nixStoreMaxSizeGiB = 80; # Soft Nix store cap in GiB; collection starts at 90% of this size or 90% usage on the filesystem containing /nix/store.
      nixGcRetentionDays = 45; # Delete profile generations older than this many days, sacrificing older rollback points.
      localNixGCMode = "capacity"; # "never", capacity-triggered collection, or unconditional "always" before deploy.
      localDiskCleanup = {
        triggerPercent = 85; # Workstation main SSD used percent that triggers conservative nix gc + log/tmpfile cleanup before deploy.
        monitorPaths = [ "/nix" ]; # Main workstation SSD mountpoint(s) to watch for capacity; the Nix store lives here.
        journalVacuumTime = "7d"; # Journal retention kept while under pressure on the workstation.
      };
      diskCleanup = {
        enable = true; # Routine conservative cleanup when a monitored filesystem reaches the trigger.
        triggerPercent = 85; # Reclaim logs, aged tmpfiles, and Nix store generations at 85% used; user data is never touched.
        monitorPaths = [ "/" ]; # Filesystems watched for capacity; user-data pools are intentionally excluded.
        journalVacuumTime = "7d"; # Journal retention kept while under pressure; normal journald retention is 30 days.
      };
    };

    dnsSettings = {
      mode = "split-horizon"; # Either "split-horizon" or "netbird-only".
    };

    edge = {
      cloudflareTunnelName = "CHANGE_ME_TUNNEL"; # Cloudflare Tunnel name from `cloudflared tunnel list`.
    };

    storage = {
      profile = "zfs-mirror"; # Storage layout: "zfs-mirror" or "single-disk-ext4".
      enableRootRollback = false; # Optional for blank installs only; requires zfs-mirror and must be chosen before running Disko.
      systemDisk = "CHANGE_ME_SYSTEM_DISK_BY_ID"; # System SSD /dev/disk/by-id basename.
      dataPool = {
        expectedGuid = null; # Optional immutable ZFS pool GUID; leave null until the first verified topology-only boot reports it.
        mirrorPairs = [
          # Verified ZFS mirror members as /dev/disk/by-id basenames; use an empty list with "single-disk-ext4".
          [
            "CHANGE_ME_DATA_DISK_1_BY_ID"
            "CHANGE_ME_DATA_DISK_2_BY_ID"
          ]
        ];
      };
    };

    offlineMedia = {
      enable = true; # Whether to provision Syncthing-backed offline media folders and enrollment tools.
    };

    mkvmaker = {
      distributedWorkers = {
        # Publish the USB-bootable NixOS worker ISO and LAN NFS exports for
        # distributed DVD-ripping workers. Disabled until that feature is
        # redeveloped; the implementation is retained as-is.
        enable = false;
      };
    };

    offsiteBackup = {
      enable = false; # Whether to mirror the encrypted Kopia repository to the opinionated MEGA destination.
      email = "REPLACE_WITH_MEGA_EMAIL"; # MEGA account email; required only when offsite backup is enabled.
      syncOnCalendar = "*-*-* 04,16:30:00"; # Check and repair the MEGA mirror once overnight and once during the day.
      repositoryLimitBytes = 19 * 1024 * 1024 * 1024; # 19 GiB preserves 1 GiB of headroom within MEGA's reported 20 GiB quota.
    };

    staleReferenceCleanup = {
      users = false; # Remove stale per-user library references after a Kanidm user is removed.
      shared = false; # Remove stale shared-library references when their source directories disappear.
    };
  };
in
(removeAttrs settings [ "offsiteBackup" ])
  // (import ./lib/derive-vars.nix { inherit lib settings; })
