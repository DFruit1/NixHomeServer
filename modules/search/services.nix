{ config, lib, pkgs, vars, appPackages, ... }:

let
  cfg = config.repo.search;
  loopback = vars.networking.loopbackIPv4;
  searchPort = vars.networking.ports.search;
  solrPort = vars.networking.ports.searchSolr;
  solrPackage = pkgs.callPackage ./solr-package.nix { };
  host = "search.${vars.domain}";
  paths = config.repo.search.paths;

  searchSettingsJson = pkgs.writeText "search-sources.json" (
    builtins.toJSON (
      lib.mapAttrsToList
        (id: source: {
          inherit id;
          display_name = source.displayName;
          source_type = source.sourceType;
          acl_group = source.aclGroup;
          app_base = source.appBase;
          settings = source.settings;
        })
        cfg.sources
    )
  );

  # Field definitions baked into the copied configset before the core is
  # created. Solr 9.10 no longer exposes the REST schema API, so the fields
  # must exist in managed-schema.xml at provisioning time.
  searchSchemaFieldsFile = pkgs.writeText "search-schema-fields.xml" (
    lib.concatStringsSep "\n" [
      "<field name=\"source\" type=\"string\" stored=\"true\" indexed=\"true\"/>"
      "<field name=\"title\" type=\"text_general\" stored=\"true\" indexed=\"true\"/>"
      # Stored: the unified highlighter fragments snippets by re-analysing the
      # stored value when the field has no term vectors. Solr compresses stored
      # fields, and queries request an explicit fl that excludes the body.
      "<field name=\"body\" type=\"text_general\" stored=\"true\" indexed=\"true\"/>"
      "<field name=\"content_type\" type=\"string\" stored=\"true\" indexed=\"true\"/>"
      "<field name=\"origin_url\" type=\"string\" stored=\"true\" indexed=\"true\"/>"
      "<field name=\"app_url\" type=\"string\" stored=\"true\" indexed=\"true\"/>"
      "<field name=\"file_path\" type=\"string\" stored=\"true\" indexed=\"false\"/>"
      "<field name=\"size_bytes\" type=\"plong\" stored=\"true\" indexed=\"false\"/>"
      "<field name=\"content_created\" type=\"pdate\" stored=\"true\" indexed=\"true\"/>"
      "<field name=\"content_modified\" type=\"pdate\" stored=\"true\" indexed=\"false\"/>"
      "<field name=\"acl_groups\" type=\"string\" stored=\"true\" indexed=\"true\" multiValued=\"true\"/>"
    ]
  );

  solrPreStartScript = pkgs.writeShellScript "search-solr-prestart" ''
    set -euo pipefail
    # Seed a writable copy of the shared _default configset: the store
    # distribution ships read-only files, and Solr persists managed schema
    # edits into the configset it created the core from. The Search fields
    # are inserted into the schema before first boot because Solr 9.10 has
    # no REST schema API.
    install -d -m 0755 ${paths.solrHome}/configsets
    if [ ! -d ${paths.solrHome}/configsets/_default ]; then
      cp -R ${solrPackage}/server/solr/configsets/_default ${paths.solrHome}/configsets/_default
      chmod -R u+w ${paths.solrHome}/configsets/_default
      conf=${paths.solrHome}/configsets/_default/conf/managed-schema.xml
      # Insert the Search fields before the schema's closing tag.
      head -n -1 "$conf" > "$conf.tmp"
      cat ${searchSchemaFieldsFile} >> "$conf.tmp"
      echo '</schema>' >> "$conf.tmp"
      mv "$conf.tmp" "$conf"
    fi
  '';

  durationSeconds = value:
    let
      parts = builtins.match "([0-9]+)([smh])" value;
      magnitude = parts: builtins.fromJSON (builtins.head parts);
      multiplier = parts: builtins.elemAt parts 1;
    in
    if parts == null then
      throw "repo.search index/reconcile periods must look like '30m', '1h', or '45s' (got '${value}')"
    else
      (magnitude parts)
      * (
        if multiplier parts == "h" then
          3600
        else if multiplier parts == "m" then
          60
        else
          1
      );

  commonEnvironment = {
    SEARCH_DATABASE_URL = "postgresql:///?host=/run/postgresql&user=search&dbname=search";
    SEARCH_SOLR_URL = "http://${loopback}:${toString solrPort}/solr";
    SEARCH_SOLR_CORE = "search";
    SEARCH_SOURCES_FILE = searchSettingsJson;
    SEARCH_ZIMDUMP = "${pkgs.zim-tools}/bin/zimdump";
    SEARCH_KIWIXSEARCH = "${pkgs.kiwix-tools}/bin/kiwix-search";
    SEARCH_PDFTOTEXT = "${pkgs."poppler-utils"}/bin/pdftotext";
  };

  hardenedService = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
  };
in
{
  options.repo.search = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to run the unified server-wide Search platform.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = appPackages.search;
      description = "Package providing the search indexer and web UI binary.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = searchPort;
      description = "Loopback port the Search web UI listens on.";
    };

    solrMaxHeap = lib.mkOption {
      type = lib.types.str;
      default = "2g";
      description = "Maximum Solr Java heap.";
    };

    indexPeriod = lib.mkOption {
      type = lib.types.str;
      default = "1h";
      description = "How often the Search indexer re-syncs every configured source.";
    };

    reconcilePeriod = lib.mkOption {
      type = lib.types.str;
      default = "1d";
      description = "How often Search purges sources whose integrations were removed.";
    };

    metadataZims = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        ZIM file-name substrings whose article titles and paths are indexed
        (metadata level). This applies only to ZIMs that lack their own
        embedded Xapian search index; archives with an embedded Xapian index
        are detected automatically and never have their articles re-extracted
        into the Search index. By default archives are indexed at archive
        level only.
      '';
    };

    fulltextZims = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        ZIM file-name substrings whose article bodies are extracted into the
        index (fulltext level, implies the metadata level). Applies only to
        ZIMs without an embedded Xapian index — such archives are detected
        automatically and their native Xapian search is used instead. Keep
        this list small: fulltext extraction reads every article and dominates
        the indexing pass. Archives whose names do not match any entry are
        indexed at archive level only.
      '';
    };

    sources = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            displayName = lib.mkOption {
              type = lib.types.str;
              description = "Human-readable source name shown in the Search UI.";
            };
            sourceType = lib.mkOption {
              type = lib.types.enum [
                "paperless"
                "kiwix"
                "browsertrix"
                "mail-archive"
                "freshrss"
              ];
              description = "Extractor used for this source.";
            };
            aclGroup = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Kanidm group that grants visibility of this source. Sources
                without a group are visible to every signed-in user.
              '';
            };
            appBase = lib.mkOption {
              type = lib.types.str;
              description = "Base URL of the origin application used for result links.";
            };
            settings = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.oneOf [
                  lib.types.str
                  lib.types.int
                  lib.types.bool
                  (lib.types.listOf lib.types.str)
                ]
              );
              default = { };
              description = "Extractor-specific settings (paths, patterns, roots).";
            };
          };
        }
      );
      default = { };
      description = ''
        Registered Search sources. Integrations populate this when the source
        application is enabled; the indexer syncs each entry into the search
        database.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    repo.storage.dataPool.guardedServices = [
      "search-solr"
      "search-solr-core-bootstrap"
      "search-ui"
      "search-index"
      "search-reconcile"
    ];

    users.groups.solr = { };
    users.users.solr = {
      isSystemUser = true;
      group = "solr";
      home = config.repo.search.paths.solrState;
      createHome = false;
    };

    # The Search database lives in the host PostgreSQL cluster. The cluster
    # itself is enabled by other modules; Search only needs its own role and
    # database.
    services.postgresql = {
      enable = true;
      ensureDatabases = [ "search" ];
      ensureUsers = [
        {
          name = "search";
          ensureDBOwnership = true;
        }
      ];
    };

    systemd.services.search-solr = {
      description = "Solr search engine for the Search platform";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment = {
        SOLR_PID_DIR = paths.solrState;
        SOLR_LOGS_DIR = "${paths.solrState}/logs";
        LOG4J_PROPS = "${solrPackage}/server/resources/log4j2.properties";
      };
      serviceConfig =
        hardenedService
        // {
          Type = "simple";
          User = "solr";
          Group = "solr";
          StateDirectory = "solr";
          LimitNOFILE = 65000;
          # Seed a writable configset with the Search schema fields baked in
          # (see solrPreStartScript).
          ExecStartPre = "${solrPreStartScript}";
          ExecStart = ''
            ${solrPackage}/bin/solr start -f \
              -p ${toString solrPort} \
              --host ${loopback} \
              --solr-home ${paths.solrHome} \
              -m ${cfg.solrMaxHeap}
          '';
          Restart = "on-failure";
          RestartSec = "5s";
        };
    };

    systemd.services.search-index = {
      description = "Index all configured sources into the Search platform";
      wantedBy = [ "multi-user.target" ];
      # A long-running loop (Type=simple) instead of a oneshot: multi-hour
      # initial extractions must never block or be killed by a NixOS
      # activation.
      environment = commonEnvironment // {
        SEARCH_INDEX_INTERVAL_SECONDS = toString (durationSeconds cfg.indexPeriod);
      };
      serviceConfig =
        hardenedService
        // {
          Type = "simple";
          User = "search";
          Group = "search";
          ExecStart = "${cfg.package}/bin/search index-daemon";
          Restart = "on-failure";
          RestartSec = "30s";
        };
    };

    systemd.services.search-reconcile = {
      description = "Purge indexed sources whose integrations were removed";
      environment = commonEnvironment;
      serviceConfig =
        hardenedService
        // {
          Type = "oneshot";
          User = "search";
          Group = "search";
          ExecStart = "${cfg.package}/bin/search reconcile";
        };
    };

    systemd.timers.search-reconcile = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10min";
        OnUnitActiveSec = cfg.reconcilePeriod;
        Persistent = true;
      };
    };

    systemd.services.search-ui = {
      description = "Unified server-wide Search web UI";
      wantedBy = [ "multi-user.target" ];
      wants = [ "search-solr-core-bootstrap.service" ];
      after = [
        "search-solr-core-bootstrap.service"
        "postgresql.service"
      ];
      environment =
        commonEnvironment
        // {
          SEARCH_UI_ADDRESS = loopback;
          SEARCH_UI_PORT = toString cfg.port;
          SEARCH_APP_BASE = "https://${host}";
          SEARCH_OIDC_ISSUER = vars.kanidmIssuer "search-web";
          SEARCH_OIDC_CLIENT_ID = "search-web";
          SEARCH_OIDC_CLIENT_SECRET_FILE = config.age.secrets.searchClientSecret.path;
        };
      serviceConfig =
        hardenedService
        // {
          Type = "simple";
          User = "search";
          Group = "search";
          ExecStart = "${cfg.package}/bin/search serve";
          ReadOnlyPaths = [ config.age.secrets.searchClientSecret.path ];
          Restart = "on-failure";
          RestartSec = "5s";
        };
    };
  };
}
