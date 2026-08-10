{ lib, ... }:

let
  settings = {
    # ---------------------------------------------------------------------------
    # Start here: these sections are the normal operator-facing settings.
    # Most admins should be able to configure a new server by editing only this
    # first block, then running `nix run .#validate-config-readiness`.
    # ---------------------------------------------------------------------------

    branding = {
      displayName = "Sydney Basin Services"; # Human-readable portal and identity-provider name.
    };

    applications = {
      # Applications are opt-in. Repository modules omitted here are neither
      # imported into this host nor included in its normal build/test worklist.
      enabled = [
        "attic"
        "audiobookshelf"
        "files"
        "immich"
        "jellyfin"
        "kavita"
        "mail-archive-ui"
        "mkvmaker"
        "offline-music"
        "paperless"
        "prowlarr"
        "qbittorrent"
        "radarr"
        "seerr"
        "sonarr"
        "vaultwarden"
        "youtube-downloader"
      ];
    };

    identity = {
      adminUser = "admindsaw"; # Dedicated Kanidm operator account; keep separate from the local Unix admin.
      appUsers = [ "dsaw" ]; # Non-admin Kanidm users granted default access to hosted apps.
      appAdminUsers = [ ]; # Extra app admins; they inherit normal app access and need not be repeated in appUsers.
      appUserEmails = {
        dsaw = "david.saw315@gmail.com"; # Mail address attached to this non-admin Kanidm user.
      }; # Optional email map for extra app users.
      adminEmail = "dsaw@tuta.io"; # Single contact address used for both ACME and the Kanidm admin account.
      sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDECt+GBZcPahwDCtWiMgn24qGdqMOJhP/pHo/pKsHAF From PC desktop into Home Server"; # Public key authorized for the local Unix administrator.
      localAdminUser = "dsaw"; # Local Unix SSH/sudo account retained for this existing server.
    };

    network = {
      hostname = "server"; # NixOS hostname and flake hostname alias.
      domain = "sydneybasiniot.org"; # Public DNS zone used for app hostnames.
      lanInterface = "enp34s0"; # Target server's wired LAN interface.
      lanIp = "192.168.8.12"; # Static LAN address for the server.
      lanPrefixLength = 24; # LAN CIDR prefix length; 24 is typical for home networks.
      lanGateway = "192.168.8.1"; # Router address on the same LAN subnet.
      netbirdIp = "100.72.113.237"; # Stable NetBird address assigned to this server.
      netbirdCidr = "100.64.0.0/10"; # NetBird network in canonical IPv4 CIDR form.
    };

    system = {
      hostPlatform = "x86_64-linux"; # Nix target platform. Supported values: "x86_64-linux" and "aarch64-linux".
      hardwareProfile = "existing-server"; # Hardware profile: "generated", "existing-server", or "generic-uefi".
      timeZone = "Australia/Sydney"; # IANA time zone for timers, logs, and local maintenance windows.
      hostId = "84e8c12a"; # Stable 8-character hexadecimal host ID required by ZFS.
      buildMode = "maximum-effort"; # Build allocation: "local", "remote", "balanced" (2 slots each with 1 requested core/job), or "maximum-effort" (all slots on both).
      nixStoreMaxSizeGiB = 80; # Soft Nix store cap in GiB; collection starts at 90% of this size or 90% usage on the filesystem containing /nix/store.
      nixGcRetentionDays = 45; # Delete profile generations older than this many days, sacrificing older rollback points.
      localNixGCMode = "capacity"; # Check workstation store pressure before deploy; collect only at the configured 90% thresholds.
    };

    dnsSettings = {
      mode = "split-horizon"; # Either "split-horizon" or "netbird-only".
    };

    edge = {
      cloudflareTunnelName = "metro"; # Cloudflare Tunnel name from `cloudflared tunnel list`.
    };

    storage = {
      profile = "zfs-mirror"; # Storage layout: "zfs-mirror" or "single-disk-ext4".
      enableRootRollback = false; # Blank-machine only: create a disposable Btrfs root and restore it from a read-only blank snapshot at every boot.
      systemDisk = "ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E"; # System SSD /dev/disk/by-id basename.
      dataPool = {
        expectedGuid = null; # Optional immutable ZFS pool GUID; leave null until the first verified topology-only boot reports it.
        mirrorPairs = [
          # Verified ZFS mirror members as /dev/disk/by-id basenames; use an empty list with "single-disk-ext4".
          [
            "ata-ST8000VN002-2ZM188_WPV3997N"
            "ata-ST8000VN002-2ZM188_WPV37712"
          ]
        ];
      };
    };

    offlineMedia = {
      enable = true; # Whether to provision Syncthing-backed offline media folders and enrollment tools.
    };

    offsiteBackup = {
      enable = true; # Whether to mirror the encrypted Kopia repository to the opinionated MEGA destination.
      email = "dsaw@tuta.io"; # MEGA account email; required only when offsite backup is enabled.
      syncOnCalendar = "*-*-* 04,16:30:00"; # Check and repair the MEGA mirror once overnight and once during the day.
      repositoryLimitBytes = 19 * 1024 * 1024 * 1024; # 19 GiB preserves 1 GiB of headroom within MEGA's reported 20 GiB quota.
    };

    staleReferenceCleanup = {
      users = true; # Remove stale per-user library references after a Kanidm user is removed.
      shared = true; # Remove stale shared-library references when their source directories disappear.
    };
  };
in
settings // (import ./lib/derive-vars.nix { inherit lib settings; })
