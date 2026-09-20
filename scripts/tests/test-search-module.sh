#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools jq nix rg

for facet in default networking identity filepaths services backups bootstrap; do
  if [[ ! -f "modules/search/${facet}.nix" ]]; then
    echo "❌ Search should keep its removable module facets explicit: missing ${facet}.nix" >&2
    exit 1
  fi
done

require_fixed modules/catalog.nix 'search = app ./search' \
  "Search should be registered in the application catalog."
require_fixed modules/catalog.nix './Integrations/expose_paperless_documents_to_search.nix' \
  "The paperless Search integration must be registered in the catalog."
require_fixed modules/catalog.nix './Integrations/expose_kiwix_archives_to_search.nix' \
  "The kiwix Search integration must be registered in the catalog."
require_fixed modules/catalog.nix './Integrations/expose_browsertrix_crawls_to_search.nix' \
  "The browsertrix Search integration must be registered in the catalog."
require_fixed modules/catalog.nix './Integrations/expose_mail_archive_emails_to_search.nix' \
  "The mail archive Search integration must be registered in the catalog."
require_fixed modules/catalog.nix './Integrations/expose_freshrss_entries_to_search.nix' \
  "The FreshRSS Search integration must be registered in the catalog."
require_fixed modules/catalog.nix './Integrations/expose_calibre_web_library_to_search.nix' \
  "The Calibre-Web Search integration must be registered in the catalog."
require_fixed modules/catalog.nix './Integrations/expose_media_manager_libraries_to_search.nix' \
  "The Media Manager library Search integration must be registered in the catalog."
require_fixed modules/Core_Modules/impermanence/default.nix '"/var/lib/solr"' \
  "Solr state should remain persistent when the Search module is removed."
for integration in expose_paperless_documents_to_search expose_kiwix_archives_to_search expose_browsertrix_crawls_to_search expose_mail_archive_emails_to_search expose_freshrss_entries_to_search expose_calibre_web_library_to_search expose_media_manager_libraries_to_search; do
  require_fixed "modules/Integrations/${integration}.nix" 'lib.hasAttrByPath [ "repo" "search" ] options' \
    "Search integrations must stay evaluable when the Search module is not imported (${integration})."
done
require_fixed modules/search/services.nix 'ensureDatabases = [ "search" ]' \
  "Search must own its database provisioning in the host PostgreSQL cluster."
require_fixed modules/search/services.nix 'solr start -f' \
  "The packaged Solr must run in the foreground under systemd."
require_fixed modules/Integrations/expose_mail_archive_emails_to_search.nix 'emailsRoots' \
  "The mail Search integration must populate the emailsRoots setting the extractor reads."
require_fixed modules/Integrations/expose_paperless_documents_to_search.nix 'sourceType = "paperless-api"' \
  "Paperless must be runtime-federated through its own API, not copied into the index."
require_fixed modules/Integrations/expose_paperless_documents_to_search.nix 'paperless-search-api-token' \
  "The Paperless Search integration must provision the API token service."
require_fixed modules/Integrations/expose_media_manager_libraries_to_search.nix 'sourceType = "media-snapshot"' \
  "Media Manager libraries must be indexed from their read-only metadata snapshots."
require_fixed modules/Integrations/expose_media_manager_libraries_to_search.nix 'users.search.extraGroups' \
  "The Media Manager Search integration must grant the indexer read access to the snapshots."
require_fixed modules/search/services.nix 'search reindex' \
  "Search must expose the DB-driven Solr rebuild command in a service."
require_fixed modules/search/services.nix 'name=\"body\" type=\"text_general\" stored=\"false\"' \
  "The Solr body field must stay index-only; the authoritative copy lives in Postgres."
require_fixed custom_apps/rust/apps/search/src/solr.rs 'author_ss' \
  "Search must index normalised author facets into Solr dynamic fields."
require_fixed custom_apps/rust/apps/search/src/solr.rs 'year_i' \
  "Search must index a normalised year facet into a Solr dynamic field."
require_fixed custom_apps/rust/apps/search/src/facets.rs 'AUTHOR_KEYS' \
  "Search must normalise extractor metadata keys into shared facet dimensions."
require_fixed custom_apps/rust/apps/search/src/ui.html 'authorFacets' \
  "The Search UI must expose the cross-source author facet."
require_fixed modules/search/backups.nix 'outputName = "search.pgdump"' \
  "The authoritative search database must be included in logical backups."
forbid_match modules/search/services.nix 'config[.]repo[.](paperless|kiwix|browsertrixDownloader|mailArchiveUi|freshrss)' \
  "The Search module must not reference other application modules directly; integrations carry that wiring."
forbid_match modules/search 'acl_group' \
  "Search must not carry per-source ACLs; access is admin-only via the shared gateway."
require_fixed modules/search/filepaths.nix 'pdfArchive' \
  "Search must define the admin PDF archive path."
require_fixed modules/search/services.nix 'search archive-pdfs' \
  "Search must expose the admin PDF archive command in a service."
require_fixed modules/search/services.nix 'SEARCH_PDF_ARCHIVE_DIR' \
  "The PDF archive service must receive its target directory."
require_fixed modules/search/services.nix 'search-pdf-archive' \
  "The PDF archive service and timer must be named consistently."
require_fixed modules/search/backups.nix 'component = "pdf-archive"' \
  "Archived PDFs must be included in the central backup inventory."
require_fixed modules/Core_Modules/impermanence/default.nix '"/var/lib/search/pdf-archive"' \
  "Archived PDFs must remain persistent when the Search module is removed."
require_fixed custom_apps/rust/apps/search/src/main.rs '"archive-pdfs" =>' \
  "The search binary must dispatch the archive-pdfs command."
if [[ ! -f custom_apps/rust/apps/search/src/pdf_archive.rs ]]; then
  echo "❌ Search must ship the admin PDF archive implementation." >&2
  exit 1
fi
require_fixed custom_apps/rust/apps/search/src/pdf_archive.rs 'pdf_urls_in_entry' \
  "The PDF archive must discover PDF links from FreshRSS entries."

host="$(test_default_host)"
result="$(NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --json --expr '
let
  flake = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  configuredVars = flake.lib.nixhomeserverSettings.${hostName};
  settings = configuredVars // {
    applications = configuredVars.applications // { enabled = [ "search" ]; };
  };
  vars = settings // (import ./lib/derive-vars.nix {
    inherit (flake.inputs.nixpkgs) lib;
    inherit settings;
  });
  pkgs = flake.inputs.nixpkgs.legacyPackages.${vars.hostPlatform};
  packageData = import ./flake/packages.nix {
    inherit (flake.inputs.nixpkgs) lib;
    inherit pkgs;
    crane = flake.inputs.crane;
  };
  system = import ./flake/system.nix {
    inputs = flake.inputs;
    inherit (flake.inputs.nixpkgs) lib;
    inherit pkgs vars;
    system = vars.hostPlatform;
    appPackages = packageData.appPackages;
  };
  host = system.nixosConfigurations.${hostName};
  cfg = host.config;
  pdfCfg = (host.extendModules {
    modules = [ { repo.search.pdfArchive.enable = true; } ];
  }).config;
  pdfArchiveService = pdfCfg.systemd.services.search-pdf-archive;
in {
  moduleEnabled = cfg.nixhomeserver.modules.search or false;
  uiUser = cfg.systemd.services.search-ui.serviceConfig.User;
  indexUser = cfg.systemd.services.search-index.serviceConfig.User;
  indexType = cfg.systemd.services.search-index.serviceConfig.Type;
  solrUser = cfg.systemd.services.search-solr.serviceConfig.User;
  solrExecStart = toString cfg.systemd.services.search-solr.serviceConfig.ExecStart;
  bootstrapExecStart = toString cfg.systemd.services.search-solr-core-bootstrap.serviceConfig.ExecStart;
  reindexExecStart = toString cfg.systemd.services.search-reindex.serviceConfig.ExecStart;
  reindexGuarded = builtins.elem "search-reindex" cfg.repo.storage.dataPool.guardedServices;
  indexAfter = cfg.systemd.services.search-index.after;
  uiCaddyHosts = cfg.services.caddy.virtualHosts ? "search.${vars.domain}";
  privateHost = cfg.services.unbound.privateHosts."search.${vars.domain}".target;
  oauthClient = cfg.services.kanidm.provision.systems.oauth2 ? "search-web";
  adminGroup = cfg.services.kanidm.provision.groups ? "search-admins";
  gatewayApp = cfg.repo.authGateway.protectedApps.search or null;
  expectedHost = "search.${vars.domain}";
  sources = builtins.attrNames cfg.repo.search.sources;
  pgDumps = map (entry: entry.database) cfg.repo.backups.postgresqlDumps;
  uiSandbox = cfg.systemd.services.search-ui.serviceConfig;
  uiPort = cfg.repo.search.port;
  uiLogoutRedirect = cfg.systemd.services.search-ui.environment.SEARCH_LOGOUT_REDIRECT_URL or null;
  fulltextZims = cfg.repo.search.fulltextZims;
  kiwixSearchBin = cfg.systemd.services.search-ui.environment.SEARCH_KIWIXSEARCH;
  zimdumpBin = cfg.systemd.services.search-ui.environment.SEARCH_ZIMDUMP;
  pdfArchiveUser = pdfArchiveService.serviceConfig.User;
  pdfArchiveExecStart = toString pdfArchiveService.serviceConfig.ExecStart;
  pdfArchiveEnvDir = pdfArchiveService.environment.SEARCH_PDF_ARCHIVE_DIR;
  pdfArchiveStateDir = pdfArchiveService.serviceConfig.StateDirectory;
  pdfArchiveGuarded = builtins.elem "search-pdf-archive" pdfCfg.repo.storage.dataPool.guardedServices;
  pdfArchiveTimer = pdfCfg.systemd.timers.search-pdf-archive.timerConfig.Persistent or false;
  pdfArchivePersisted = builtins.elem pdfCfg.repo.search.paths.pdfArchive pdfCfg.repo.impermanence.inventory.persistenceDirectories;
  pdfArchiveBackup = builtins.any
    (entry: entry.app == "search" && entry.component == "pdf-archive")
    pdfCfg.repo.backups.appStateEntries;
}')"

if ! jq -e '
  .moduleEnabled
  and (.uiUser == "search")
  and (.indexUser == "search")
  and (.solrUser == "solr")
  and (.solrExecStart | contains("solr start -f"))
  and (.bootstrapExecStart | contains("search bootstrap-solr"))
  and (.reindexExecStart | contains("search reindex"))
  and .reindexGuarded
  and (.indexType == "simple")
  and (.indexAfter | index("data-pool-layout.service") != null)
  and .uiCaddyHosts
  and (.privateHost == "private")
  and (.oauthClient == false)
  and .adminGroup
  and (.gatewayApp != null)
  and (.gatewayApp.host == .expectedHost)
  and (.gatewayApp.upstream == "http://127.0.0.1:8092")
  and (.gatewayApp.allowedGroups == ["search-admins"])
  and (.sources | length == 0)
  and (.pgDumps | index("search") != null)
  and (.uiSandbox.NoNewPrivileges == true)
  and (.uiSandbox.ProtectSystem == "strict")
  and (.uiPort == 8092)
  and (.uiLogoutRedirect != null)
  and (.uiLogoutRedirect | contains("/oauth2/sign_out"))
  and (.fulltextZims | type == "array")
  and (.kiwixSearchBin | contains("kiwix-search"))
  and (.zimdumpBin | contains("zimdump"))
  and (.pdfArchiveUser == "search")
  and (.pdfArchiveExecStart | contains("search archive-pdfs"))
  and (.pdfArchiveEnvDir == "/var/lib/search/pdf-archive")
  and (.pdfArchiveStateDir == "search/pdf-archive")
  and .pdfArchiveGuarded
  and .pdfArchiveTimer
  and .pdfArchivePersisted
  and .pdfArchiveBackup
' <<<"$result" >/dev/null; then
  echo "❌ Search module invariants were not satisfied." >&2
  jq . <<<"$result" >&2
  exit 1
fi

echo "✅ Search module tests passed."
