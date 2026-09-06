{ config, lib, options, vars, pkgs, ... }:

{
  config = lib.optionalAttrs
    (
      lib.hasAttrByPath [ "repo" "search" ] options
      && lib.hasAttrByPath [ "repo" "browsertrixDownloader" ] options
    )
    (lib.mkIf config.repo.search.enable {
      repo.search.sources.browsertrix = {
        displayName = "Web Archives";
        sourceType = "browsertrix";
        aclGroup = "web-archive-users";
        appBase = "https://archives.${vars.domain}";
        settings = {
          archiveRoot = config.repo.browsertrixDownloader.paths.archiveRoot;
        };
      };

      # The indexer reads completed WACZ archives.
      users.users.search.extraGroups = lib.mkAfter [ "browsertrix-downloader" ];

      # The WACZ archive root lives under the shared data pool, where only the
      # downloader user and the shared-access group may enter. The indexer runs
      # as the search user, so grant it (and future WACZ files created in the
      # tree) read-only access through POSIX ACLs.
      systemd.services.search-browsertrix-acl = {
        description = "Grant the Search indexer read access to the WACZ archive root";
        wantedBy = [ "multi-user.target" ];
        requires = [ "data-pool-layout.service" ];
        after = [ "data-pool-layout.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "search-browsertrix-acl" ''
            set -euo pipefail
            root=${lib.escapeShellArg config.repo.browsertrixDownloader.paths.archiveRoot}
            if [ ! -d "$root" ]; then
              echo "WACZ archive root '$root' does not exist" >&2
              exit 1
            fi
            ${pkgs.acl}/bin/setfacl -R -m g:search:r-X "$root"
            ${pkgs.acl}/bin/setfacl -m d:g:search:r-X "$root"
          '';
        };
      };

      systemd.services.search-index.after = [ "search-browsertrix-acl.service" ];
    });
}
