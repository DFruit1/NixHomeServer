{ appPackages, config, lib, vars, ... }:

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
    };
  };
  hasModule = name: config.nixhomeserver.modules.${name} or false;
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

  config.repo.mediaManager.integrations = {
    jellyfin = {
      label = "Jellyfin";
      available = hasModule "jellyfin";
      capabilities = [ "library-refresh" ];
    };
    audiobookshelf = {
      label = "Audiobookshelf";
      available = hasModule "audiobookshelf";
      capabilities = [ "library-refresh" ];
    };
    kavita = {
      label = "Kavita";
      available = hasModule "kavita";
      capabilities = [ "library-refresh" ];
    };
    syncthing = {
      label = "Syncthing";
      available = config.services.syncthing.enable or false;
      capabilities = [ "folder-rescan" ];
    };
  };
}
