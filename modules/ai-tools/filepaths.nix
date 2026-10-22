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
      path = with pkgs; [ acl coreutils findutils gnugrep ];
      script = ''
        set -euo pipefail

        root=${lib.escapeShellArg vars.sharedRoot}

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
        if ((missing != 0)); then
          exit 1
        fi
      '';
    };
  };
}