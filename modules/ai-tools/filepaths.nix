{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.aiTools;
in
{
  config = lib.mkIf cfg.enable {
    # Both units touch the data pool: the ACL grant rewrites the shared root
    # and the service reads documents out of it, so neither may start before the
    # pool layout is in place.
    repo.storage.dataPool.guardedServices = [
      "ai-tools-shared-access"
      "ai-tools"
    ];

    # convert_document reads documents out of the shared root, so the service
    # account needs to traverse and read it. Every other read-only consumer
    # (calibre-web, media-manager) is granted the same access here, and
    # ai-tools is confined to this one path by ProtectSystem plus ReadOnlyPaths
    # in services.nix, so the grant cannot be used to read anything else.
    systemd.services.ai-tools-shared-access = {
      description = "Grant the AI Tools service read-only access to the shared root";
      wantedBy = [ "multi-user.target" ];
      before = [ "ai-tools.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = with pkgs; [ acl coreutils gnugrep ];
      script = ''
        set -euo pipefail

        root=${lib.escapeShellArg vars.sharedRoot}

        # Re-apply on every activation: entries copied in by other applications
        # (Syncthing, torrent clients) do not inherit the default ACL that was
        # applied when they were created, and a one-time grant would miss them.
        setfacl -m "g:ai-tools:r-x" -m "d:g:ai-tools:r-x" "$root"
        if ! getfacl -cp "$root" | grep -q '^group:ai-tools:r-x$'; then
          echo "failed: ${lib.escapeShellArg vars.sharedRoot} does not grant read access to ai-tools" >&2
          exit 1
        fi
      '';
    };
  };
}