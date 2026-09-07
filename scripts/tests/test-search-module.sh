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
require_fixed modules/Core_Modules/impermanence/default.nix '"/var/lib/solr"' \
  "Solr state should remain persistent when the Search module is removed."
require_fixed modules/Core_Modules/age/default.nix 'searchClientSecret' \
  "The Search OIDC client secret must be declared for agenix."
for integration in expose_paperless_documents_to_search expose_kiwix_archives_to_search expose_browsertrix_crawls_to_search expose_mail_archive_emails_to_search expose_freshrss_entries_to_search; do
  require_fixed "modules/Integrations/${integration}.nix" 'lib.hasAttrByPath [ "repo" "search" ] options' \
    "Search integrations must stay evaluable when the Search module is not imported (${integration})."
done
require_fixed modules/search/services.nix 'ensureDatabases = [ "search" ]' \
  "Search must own its database provisioning in the host PostgreSQL cluster."
require_fixed modules/search/services.nix 'solr start -f' \
  "The packaged Solr must run in the foreground under systemd."
require_fixed modules/search/backups.nix 'outputName = "search.pgdump"' \
  "The authoritative search database must be included in logical backups."
forbid_match modules/search/services.nix 'config[.]repo[.](paperless|kiwix|browsertrixDownloader|mailArchiveUi|freshrss)' \
  "The Search module must not reference other application modules directly; integrations carry that wiring."

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
  cfg = system.nixosConfigurations.${hostName}.config;
in {
  moduleEnabled = cfg.nixhomeserver.modules.search or false;
  uiUser = cfg.systemd.services.search-ui.serviceConfig.User;
  indexUser = cfg.systemd.services.search-index.serviceConfig.User;
  indexType = cfg.systemd.services.search-index.serviceConfig.Type;
  solrUser = cfg.systemd.services.search-solr.serviceConfig.User;
  solrExecStart = toString cfg.systemd.services.search-solr.serviceConfig.ExecStart;
  bootstrapExecStart = toString cfg.systemd.services.search-solr-core-bootstrap.serviceConfig.ExecStart;
  indexAfter = cfg.systemd.services.search-index.after;
  uiCaddyHosts = cfg.services.caddy.virtualHosts ? "search.${vars.domain}";
  privateHost = cfg.services.unbound.privateHosts."search.${vars.domain}".target;
  oauthClient = cfg.services.kanidm.provision.systems.oauth2 ? "search-web";
  kanidmGroup = cfg.services.kanidm.provision.groups ? "search-users";
  sources = builtins.attrNames cfg.repo.search.sources;
  pgDumps = map (entry: entry.database) cfg.repo.backups.postgresqlDumps;
  uiSandbox = cfg.systemd.services.search-ui.serviceConfig;
  uiPort = cfg.repo.search.port;
  uiSecret = cfg.systemd.services.search-ui.environment.SEARCH_OIDC_CLIENT_SECRET_FILE;
  fulltextZims = cfg.repo.search.fulltextZims;
  kiwixSearchBin = cfg.systemd.services.search-ui.environment.SEARCH_KIWIXSEARCH;
  zimdumpBin = cfg.systemd.services.search-ui.environment.SEARCH_ZIMDUMP;
}')"

if ! jq -e '
  .moduleEnabled
  and (.uiUser == "search")
  and (.indexUser == "search")
  and (.solrUser == "solr")
  and (.solrExecStart | contains("solr start -f"))
  and (.bootstrapExecStart | contains("search bootstrap-solr"))
  and (.indexType == "simple")
  and (.indexAfter | index("data-pool-layout.service") != null)
  and .uiCaddyHosts
  and (.privateHost == "private")
  and .oauthClient
  and .kanidmGroup
  and (.sources | length == 0)
  and (.pgDumps | index("search") != null)
  and (.uiSandbox.NoNewPrivileges == true)
  and (.uiSandbox.ProtectSystem == "strict")
  and (.uiPort == 8092)
  and (.uiSecret | contains("searchClientSecret"))
  and (.fulltextZims | type == "array")
  and (.kiwixSearchBin | contains("kiwix-search"))
  and (.zimdumpBin | contains("zimdump"))
' <<<"$result" >/dev/null; then
  echo "❌ Search module invariants were not satisfied." >&2
  jq . <<<"$result" >&2
  exit 1
fi

echo "✅ Search module tests passed."
