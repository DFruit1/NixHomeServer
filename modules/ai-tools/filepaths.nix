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
      path = with pkgs; [ acl coreutils findutils gnugrep ];
      script = ''
        set -euo pipefail

        root=${lib.escapeShellArg cfg.sharedRoot}
        workspace=${lib.escapeShellArg cfg.workspaceRoot}

        # Re-apply on every activation, and over the whole tree rather than the
        # root: a default ACL only covers entries created after it was applied,
        # so documents that already existed, and directories copied in by other
        # applications (Syncthing, torrent clients), carry no ai-tools entry and
        # convert_document would be refused with EACCES. A one-time root grant
        # left every existing document unreadable while its verification passed.
        #
        # -P keeps setfacl from following symbolic links, so a link inside the
        # root cannot pull content from outside it into the grant, and r-X keeps
        # the grant read-only: the service may not modify what it converts.
        setfacl -P -R -m "g:ai-tools:r-X" "$root"
        find "$root" -type d -exec setfacl -m "d:g:ai-tools:r-x" '{}' +

        # The workspace is the one directory ai-tools may write to. It is
        # granted after the recursive read grant above, so the write entry is
        # the one that survives: the shared root stays read-only, and the write
        # grant is scoped to the workspace inside it. The workspace exists
        # through contentSubdirs, but install -d is kept so the grant still
        # applies if the data-pool layout has not run yet on a hand-built root,
        # and it resets the mode to the shared content mode.
        install -d -m 0770 -o root -g root "$workspace"
        setfacl -m "g:ai-tools:rwx" -m "d:g:ai-tools:rwx" "$workspace"
        # Content already in the workspace, from an earlier run or copied in by
        # the owner, needs the mask too, or existing files stay read-only while
        # newly created ones are writable.
        setfacl -P -R -m g:ai-tools:rwX "$workspace"

        # Verify content, not the root: sample the root, every immediate child
        # and one deeper entry, which is where a root-only grant shows up. Bounded
        # on purpose, because this runs on the whole shared root at activation.
        missing=0
        check_entry() {
          # Capture before matching: `grep -q` closes the pipe on the first hit,
          # and getfacl killed by SIGPIPE would fail the pipeline under pipefail.
          local acls
          acls="$(getfacl -cp "$1")"
          if ! grep -q "^group:ai-tools:r" <<<"$acls"; then
            echo "failed: $1 does not grant read access to ai-tools" >&2
            missing=1
          fi
        }
        check_entry "$root"
        while IFS= read -r -d $'\0' entry; do
          check_entry "$entry"
        done < <(find "$root" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) -print0)
        deeper="$(find "$root" -mindepth 2 \( -type f -o -type d \) -print -quit)"
        [[ -z "$deeper" ]] || check_entry "$deeper"
        # The workspace is the write half, so it is verified by name: a read
        # grant alone would leave convert_document unable to write its output.
        if ! grep -q "^group:ai-tools:rwx$" <<<"$(getfacl -cp "$workspace")"; then
          echo "failed: ${lib.escapeShellArg cfg.workspaceRoot} does not grant write access to ai-tools" >&2
          missing=1
        fi
        if ((missing != 0)); then
          exit 1
        fi
      '';
    };
  };
}
