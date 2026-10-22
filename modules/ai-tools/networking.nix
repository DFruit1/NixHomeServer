{ config, lib, vars, ... }:

let
  cfg = config.repo.aiTools;
in
{
  options.repo.aiTools = {
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = vars.networking.loopbackIPv4;
      readOnly = true;
      description = "Loopback-only MCP listen address. The gateway is the only client.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = vars.networking.ports.aiTools or 8097;
      description = "Local MCP Streamable HTTP port.";
    };

    searxngTimeoutSecs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20;
      description = "Upstream timeout for a SearXNG query, in seconds.";
    };

    maxResults = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
      description = "Upper bound on results returned by web_search.";
    };
  };

  config = lib.mkIf cfg.enable {
    repo.authGateway.protectedApps.aiTools = {
      host = "tools.${vars.domain}";
      upstream = "http://${cfg.listenAddress}:${toString cfg.port}";
      allowedGroups = [ "ai-users" ];
      apiUnauthenticated401 = true;
    };

    services.unbound.privateHosts."tools.${vars.domain}".target = "private";

    assertions = [
      {
        assertion = cfg.listenAddress == vars.networking.loopbackIPv4;
        message = "repo.aiTools.listenAddress must stay on IPv4 loopback; the gateway is the only client.";
      }
      {
        assertion = config.repo.authGateway.enable && config.repo.authGateway.mode == "gateway";
        message = "The AI Tools MCP endpoint requires the shared authentication gateway.";
      }
      {
        # The workspace is a child of the shared root by construction, and the
        # sandbox only produces the intended confinement if that holds. A
        # workspace outside the shared root would leave it uncovered by
        # ReadOnlyPaths, and one equal to the shared root would make every read
        # path writable.
        assertion = lib.hasPrefix "${cfg.sharedRoot}/" cfg.workspaceRoot
          && cfg.workspaceRoot != cfg.sharedRoot;
        message = "repo.aiTools.workspaceRoot must be a subdirectory of repo.aiTools.sharedRoot, so the read-only root and the writable workspace do not overlap.";
      }
      {
        # The workspace is deliberately unbacked-up, which holds because it is
        # on the data pool and no snapshot root covers that pool. If a future
        # module widened a snapshot root to reach it, this would silently start
        # backing up scratch output, so the claim is asserted rather than
        # assumed.
        assertion = !lib.any
          (root: cfg.workspaceRoot == root || lib.hasPrefix "${root}/" cfg.workspaceRoot)
          config.repo.backups.snapshotRoots;
        message = "repo.aiTools.workspaceRoot must stay outside every repo.backups.snapshotRoots entry; the workspace is deliberately not backed up.";
      }
    ];
  };
}
