{ config, lib, vars, ... }:

let
  cfg = config.repo.search;
  loopback = vars.networking.loopbackIPv4;
  solrPort = vars.networking.ports.searchSolr;
in
{
  config = lib.mkIf cfg.enable {
    # Seeds the shared `_default` configset into the Solr home, then creates
    # the search core and its schema through the Core/Schema APIs. The core
    # is derived state: if it is ever lost this bootstrap recreates it.
    systemd.services.search-solr-core-bootstrap = {
      description = "Create the Search Solr core and schema";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "search-solr.service"
        "postgresql.service"
      ];
      after = [
        "search-solr.service"
        "postgresql.service"
      ];
      before = [ "search-ui.service" ];
      environment = {
        SEARCH_SOLR_URL = "http://${loopback}:${toString solrPort}/solr";
        SEARCH_SOLR_CORE = "search";
        SEARCH_SOLR_CONFIGSET = "_default";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "search";
        Group = "search";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        ExecStart = "${cfg.package}/bin/search bootstrap-solr";
      };
    };
  };
}
