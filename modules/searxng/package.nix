{ config, lib, pkgs, ... }:

let
  cfg = config.repo.searxng;

  settings = pkgs.writeText "searxng-settings.yml" ''
    use_default_settings: true
    general:
      instance_name: "home server"
    server:
      # Only the loopback ai-tools service queries this instance. The gateway
      # never publishes SearXNG directly.
      bind_address: "127.0.0.1"
      port: ${toString cfg.port}
      secret_key: "generated-per-boot-not-used-for-public-listen"
      limiter: false
      image_proxy: false
    search:
      # The MCP web_search tool reads the JSON format. It is not in
      # use_default_settings, so it must be enabled explicitly here.
      formats:
        - html
        - json
    outcoming:
      request_timeout: 6.0
      max_request_timeout: 12.0
  '';
in
{
  options.repo.searxng = {
    enable = lib.mkEnableOption ''
      Self-hosted SearXNG metasearch backing the local model's web_search tool.
      Loopback-only and never published through the gateway.
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.searxng;
      readOnly = true;
      description = "SearXNG package providing the loopback searxng-run entry point.";
    };

    settingsFile = lib.mkOption {
      type = lib.types.path;
      default = settings;
      readOnly = true;
      description = ''
        Generated settings.yml. The JSON search format is enabled explicitly
        because it is not part of use_default_settings, and web_search needs it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.searxng ];
  };
}
