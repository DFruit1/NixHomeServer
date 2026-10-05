{ config, lib, pkgs, ... }:

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

    # The workspace is the one directory ai-tools may write to. Declaring it
    # here means the data-pool layout provisions it with the shared content mode
    # (0770, root:root) before either unit runs, so the ACL unit never has to
    # invent a path. It is persisted on the ZFS data pool and deliberately not
    # backed up: no repo.backups.snapshotRoots entry covers it, which
    # networking.nix asserts rather than assumes.
    repo.storage.sharedRoots.contentSubdirs = [ cfg.workspaceDirName ];

    # convert_document reads documents out of the shared root, so the service
    # account needs to traverse and read it. Every other read-only consumer
    # (calibre-web, media-manager) is granted the same access here, and
    # ai-tools is confined to sharedRoot plus the writable workspace by
    # ProtectSystem plus ReadOnlyPaths/ReadWritePaths in services.nix, so the
    # read grant cannot be used to read or write anything else.
    systemd.services.ai-tools-shared-access = {
      description = "Grant the AI Tools service read access to the shared root and write access to its workspace";
      wantedBy = [ "multi-user.target" ];
      before = [ "ai-tools.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = with pkgs; [ acl coreutils gnugrep ];
      script = ''
        set -euo pipefail

        root=${lib.escapeShellArg cfg.sharedRoot}
        workspace=${lib.escapeShellArg cfg.workspaceRoot}

        # Re-apply on every activation: entries copied in by other applications
        # (Syncthing, torrent clients) do not inherit the default ACL that was
        # applied when they were created, and a one-time grant would miss them.
        # The shared root itself stays read-only for ai-tools; the write grant is
        # scoped to the workspace, not to the root it lives in.
        setfacl -m "g:ai-tools:r-x" -m "d:g:ai-tools:r-x" "$root"

        # The workspace exists through contentSubdirs, but install -d is kept
        # so the grant still applies if the data-pool layout has not run yet on
        # a hand-built root, and it resets the mode to the shared content mode.
        install -d -m 0770 -o root -g root "$workspace"
        setfacl -m "g:ai-tools:rwx" -m "d:g:ai-tools:rwx" "$workspace"
        # Content already in the workspace, from an earlier run or copied in by
        # the owner, needs the mask too, or existing files stay read-only while
        # newly created ones are writable.
        setfacl -P -R -m g:ai-tools:rwX "$workspace"

        if ! getfacl -cp "$root" | grep -q '^group:ai-tools:r-x$'; then
          echo "failed: ${lib.escapeShellArg cfg.sharedRoot} does not grant read access to ai-tools" >&2
          exit 1
        fi
        if ! getfacl -cp "$workspace" | grep -q '^group:ai-tools:rwx$'; then
          echo "failed: ${lib.escapeShellArg cfg.workspaceRoot} does not grant write access to ai-tools" >&2
          exit 1
        fi
      '';
    };
  };
}
