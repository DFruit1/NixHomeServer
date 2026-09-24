{ appPackages, lib, vars, ... }:

let
  rootType = lib.types.submodule {
    options = {
      id = lib.mkOption { type = lib.types.str; };
      label = lib.mkOption { type = lib.types.str; };
      category = lib.mkOption { type = lib.types.enum [ "videos" "music" "audiobooks" "podcasts" "books" "iso" ]; };
      scope = lib.mkOption { type = lib.types.enum [ "shared" "personal" ]; };
      pathTemplate = lib.mkOption {
        type = lib.types.str;
        description = "Server-owned path template. Personal templates contain exactly one {username} component.";
      };
    };
  };
  integrationType = lib.types.submodule {
    options = {
      label = lib.mkOption { type = lib.types.str; };
      available = lib.mkOption { type = lib.types.bool; default = false; };
      capabilities = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Browser-facing URL for integrations that hand off to another application.";
      };
      environment = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; };
      readOnlyPaths = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      refresh = lib.mkOption {
        default = null;
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            unit = lib.mkOption { type = lib.types.strMatching "[a-zA-Z0-9@_.:-]+[.]service"; };
            metadataUnit = lib.mkOption {
              type = lib.types.either (lib.types.enum [ "" ]) (lib.types.strMatching "[a-zA-Z0-9@_.:-]+[.]service");
              default = "";
            };
            successMessage = lib.mkOption { type = lib.types.str; };
            failureMessage = lib.mkOption { type = lib.types.str; };
          };
        });
        description = "Configuration-owned refresh units; browser requests can only select a registered integration ID.";
      };
    };
  };
  catalog = import ../../catalog.nix;
in
{
  options.repo.mediaManager = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      readOnly = true;
      description = "Media Manager is an always-present core service.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = appPackages.media-manager;
      description = "Media Manager package.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "media.${vars.domain}";
      readOnly = true;
    };
    address = lib.mkOption {
      type = lib.types.str;
      default = vars.networking.loopbackIPv4;
      readOnly = true;
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = vars.networking.ports.mediaManager;
      readOnly = true;
    };
    providerPort = lib.mkOption {
      type = lib.types.port;
      default = vars.networking.ports.mediaManagerProvider;
      readOnly = true;
      description = "Loopback-only runtime provider account broker port.";
    };
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/media-manager";
      readOnly = true;
    };
    providerStateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/media-manager-provider";
      readOnly = true;
      description = "Broker-only encrypted provider account state.";
    };
    editorGroup = lib.mkOption {
      type = lib.types.str;
      default = "media-manager-editors";
      readOnly = true;
    };
    mutationMode = lib.mkOption {
      type = lib.types.enum [ "read-only" "enabled" ];
      default = "enabled";
      description = "Set to read-only to disable confirmation and the separate mutation-broker timer.";
    };
    roots = lib.mkOption {
      type = lib.types.listOf rootType;
      readOnly = true;
      default = [
        { id = "shared-videos"; label = "Shared videos"; category = "videos"; scope = "shared"; pathTemplate = "${vars.sharedRoot}/_Videos"; }
        { id = "shared-music"; label = "Shared music"; category = "music"; scope = "shared"; pathTemplate = "${vars.sharedRoot}/_Music"; }
        { id = "shared-audiobooks"; label = "Shared audiobooks"; category = "audiobooks"; scope = "shared"; pathTemplate = "${vars.sharedRoot}/_Audiobooks"; }
        { id = "shared-podcasts"; label = "Shared podcasts"; category = "podcasts"; scope = "shared"; pathTemplate = "${vars.sharedRoot}/_Podcasts"; }
        { id = "shared-books"; label = "Shared books"; category = "books"; scope = "shared"; pathTemplate = "${vars.sharedRoot}/_Books"; }
        { id = "personal-videos"; label = "My videos"; category = "videos"; scope = "personal"; pathTemplate = "${vars.usersRoot}/{username}/_Videos"; }
        { id = "personal-music"; label = "My music"; category = "music"; scope = "personal"; pathTemplate = "${vars.usersRoot}/{username}/_Music"; }
        { id = "personal-audiobooks"; label = "My audiobooks"; category = "audiobooks"; scope = "personal"; pathTemplate = "${vars.usersRoot}/{username}/_Audiobooks"; }
        { id = "personal-podcasts"; label = "My podcasts"; category = "podcasts"; scope = "personal"; pathTemplate = "${vars.usersRoot}/{username}/_Podcasts"; }
        { id = "personal-books"; label = "My books"; category = "books"; scope = "personal"; pathTemplate = "${vars.usersRoot}/{username}/_Books"; }
      ];
    };
    integrations = lib.mkOption {
      type = lib.types.attrsOf integrationType;
      default = { };
      description = "Typed, optional application capabilities exposed without making those applications dependencies.";
    };
  };

  config.repo.mediaManager.integrations = lib.mapAttrs
    (_: entry: entry.registration.mediaManager)
    (lib.filterAttrs (_: entry: entry.registration ? mediaManager) catalog.apps);
}
