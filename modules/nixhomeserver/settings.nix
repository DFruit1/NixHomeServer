{ config, lib, vars, ... }:

let
  defaults = import ./defaults.nix { inherit lib; };
  cfg = config.nixhomeserver;
  enabledByProfiles = defaults.profileApps cfg.profiles;
  varsAppEnables = {
    audiobookshelf = vars.apps.audiobooks.enable or false;
    copyparty = vars.apps.uploads.enable or false;
    "filebrowser-quantum" = vars.apps.files.enable or false;
    glances = vars.apps.monitoring.enable or false;
    immich = vars.apps.photos.enable or false;
    jellyfin = vars.apps.videos.enable or false;
    kavita = vars.apps.books.enable or false;
    kiwix = vars.apps.wiki.enable or false;
    "mail-archive" = vars.apps.mail.enable or false;
    "mail-archive-ui" = vars.apps.mail.enable or false;
    metube = vars.apps.downloads.enable or false;
    paperless = vars.apps.documents.enable or false;
    vaultwarden = vars.apps.passwords.enable or false;
  };
  hasVarsAppToggles = vars ? apps;
  externallyBoundPorts = lib.filterAttrs (name: _: !(lib.hasSuffix "Container" name)) vars.networking.ports;
  portValues = lib.attrValues externallyBoundPorts;
  uniquePortValues = lib.unique portValues;
  containsChangeMe = value:
    let
      text = toString value;
    in
    lib.hasInfix "CHANGE_ME" text;
  mkAppOption = name: lib.mkOption {
    type = lib.types.submodule {
      options.enable = lib.mkEnableOption "the ${name} app integration";
    };
    default = { };
    description = "Controls whether the ${name} app is part of this host profile.";
  };
in
{
  options.nixhomeserver = {
    profiles = lib.mkOption {
      type = lib.types.listOf (lib.types.enum defaults.profileNames);
      default = [ "compatibility" ];
      description = "Install profiles enabled for this host.";
    };

    apps = lib.genAttrs defaults.appNames mkAppOption;

    settings = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      description = "Resolved site settings in the legacy vars-compatible shape.";
    };

    identity = {
      adminUser = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        description = "Delegated Kanidm operator user.";
      };
      adminEmail = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        description = "Delegated Kanidm operator email.";
      };
    };

    networking = {
      domain = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        description = "Primary public DNS domain for the host.";
      };
      lanInterface = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        description = "LAN interface name used by the static host address.";
      };
      lanAddress = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        description = "Static LAN IPv4 address.";
      };
      dnsMode = lib.mkOption {
        type = lib.types.enum [ "split-horizon" "netbird-only" ];
        readOnly = true;
        description = "Private DNS publication mode.";
      };
    };

    storage = {
      systemDisk = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        description = "System disk by-id basename.";
      };
      dataPool = lib.mkOption {
        type = lib.types.attrs;
        readOnly = true;
        description = "ZFS data pool settings.";
      };
    };

    edge = {
      cloudflareTunnelName = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        description = "Cloudflare Tunnel name.";
      };
    };

    backups = {
      enableSystemState = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether the system-state backup integration is expected for this host.";
      };
    };

    validation = {
      allowPlaceholders = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Allow example placeholder values to evaluate for template hosts.";
      };
    };
  };

  config = {
    nixhomeserver = {
      settings = vars;
      identity = {
        adminUser = vars.kanidmAdminUser;
        adminEmail = vars.kanidmAdminEmail;
      };
      networking = {
        domain = vars.domain;
        lanInterface = vars.netIface;
        lanAddress = vars.serverLanIP;
        dnsMode = vars.dnsMode;
      };
      storage = {
        systemDisk = vars.mainDisk;
        dataPool = vars.zfsDataPool;
      };
      edge.cloudflareTunnelName = vars.cloudflareTunnelName;
    };

    nixhomeserver.apps = lib.genAttrs defaults.appNames (name: {
      enable = lib.mkDefault (
        if hasVarsAppToggles then
          varsAppEnables.${name}
        else
          builtins.elem name enabledByProfiles
      );
    });

    assertions = [
      {
        assertion = cfg.validation.allowPlaceholders || vars.domain != "example.test";
        message = "nixhomeserver: replace the example domain before using this host for install/deploy.";
      }
      {
        assertion = cfg.validation.allowPlaceholders || !containsChangeMe vars.serverSSHPubKey;
        message = "nixhomeserver: replace serverSSHPubKey with a real SSH public key.";
      }
      {
        assertion = cfg.validation.allowPlaceholders || !containsChangeMe vars.netIface;
        message = "nixhomeserver: replace the LAN interface placeholder.";
      }
      {
        assertion = cfg.validation.allowPlaceholders || !containsChangeMe vars.mainDisk;
        message = "nixhomeserver: replace mainDisk with a /dev/disk/by-id basename.";
      }
      {
        assertion = cfg.validation.allowPlaceholders || !(lib.any containsChangeMe vars.zfsDataPoolDiskIds);
        message = "nixhomeserver: replace all ZFS data-pool disk placeholders.";
      }
      {
        assertion = builtins.elem vars.dnsMode [ "split-horizon" "netbird-only" ];
        message = "nixhomeserver: dnsMode must be either split-horizon or netbird-only.";
      }
      {
        assertion = builtins.length portValues == builtins.length uniquePortValues;
        message = "nixhomeserver: vars.networking.ports contains duplicate port values.";
      }
      {
        assertion = vars.photosDomain != vars.sharePhotosDomain;
        message = "nixhomeserver: private Immich and public share hostnames must be distinct.";
      }
    ];
  };
}
