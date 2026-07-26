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

    identity = {
      adminUser = "kanidm-admin"; # Dedicated Kanidm operator account; keep separate from the local Unix admin.
      appUsers = [ ]; # Extra existing Kanidm users granted default access to hosted apps.
      appAdminUsers = [ ]; # Extra app admins; they inherit normal app access and need not be repeated in appUsers.
      appUserEmails = { }; # Optional email map for extra app users, for example { alice = "alice@example.test"; }.
      adminEmail = "admin@example.test"; # Single contact address used for both ACME and the Kanidm admin account.
      sshPublicKey = "ssh-ed25519 CHANGE_ME example-admin-key"; # Public key authorized for the local Unix administrator.
      localAdminUser = "admin"; # Local Unix SSH/sudo account for bootstrap and operations.
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

    fileAccess = {
      usbUsers = [ ]; # Kanidm users allowed to see _USB inside their personal file root.
    };

    backupAccess = {
      adminUsers = [ ]; # Extra existing Kanidm users allowed to manage backups.
      storageUsers = [ ]; # Storage-only users. Backup admins inherit storage access and should not be repeated here.
    };

    seerrAccess = {
      requestManagers = [ ]; # Extra request approvers; the dedicated Kanidm admin is always included.
    };

    offlineMedia = {
      enable = true; # Whether to provision Syncthing-backed offline media folders and enrollment tools.
    };

    binaryCaches = [ ]; # Optional extra binary caches: [{ url = "https://example.cachix.org"; publicKey = "example.cachix.org-1:..."; }].

    offsiteBackup = {
      enable = false; # Whether to mirror the encrypted Kopia repository to the opinionated MEGA destination.
      email = "REPLACE_WITH_MEGA_EMAIL"; # MEGA account email; required only when offsite backup is enabled.
      syncOnCalendar = "*-*-* 04:30:00"; # systemd calendar expression controlling when the daily mirror starts.
      repositoryLimitBytes = 19327352832; # Maximum remote repository size in bytes; 18 GiB preserves 2 GiB of MEGA headroom.
    };

    staleReferenceCleanup = {
      users = false; # Remove stale per-user library references after a Kanidm user is removed.
      shared = false; # Remove stale shared-library references when their source directories disappear.
    };
  };
in
(removeAttrs settings [ "offsiteBackup" ])
  // (import ./lib/derive-vars.nix { inherit lib settings; })
