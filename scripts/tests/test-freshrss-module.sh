#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg sqlite3

require_fixed modules/freshrss/services.nix 'authType = "http_auth";' \
  "FreshRSS must use its supported HTTP-auth mode behind the OIDC gateway."
require_fixed modules/freshrss/services.nix 'webserver = "caddy";' \
  "FreshRSS must reuse the existing Caddy service."
require_fixed modules/freshrss/services.nix 'database.type = "sqlite";' \
  "FreshRSS storage must remain explicitly pinned to SQLite."
require_fixed modules/freshrss/services.nix 'api.enable = true;' \
  "FreshRSS must enable per-user API passwords for native clients."
require_fixed modules/freshrss/services.nix 'nativeAuthPaths = [ "/api/greader.php" "/api/greader.php/*" ];' \
  "Only FreshRSS's API-password-authenticated Google Reader endpoint may bypass browser OIDC."
require_fixed modules/Core_Modules/auth-gateway/default.nix '"Remote-User"' \
  "The gateway must strip FreshRSS's alternate Remote-User identity header."
require_fixed modules/Core_Modules/auth-gateway/default.nix '"X-WebAuth-User"' \
  "The gateway must strip FreshRSS's alternate X-WebAuth-User identity header."
require_fixed modules/Core_Modules/auth-gateway/default.nix '"Remote_User"' \
  "The gateway must strip the underscore alias that FastCGI can map to HTTP_REMOTE_USER."
require_fixed modules/Core_Modules/auth-gateway/default.nix '"X_WebAuth_User"' \
  "The gateway must strip the underscore alias that FastCGI can map to HTTP_X_WEBAUTH_USER."
require_fixed modules/freshrss/services.nix 'env REMOTE_USER {http.request.header.X-Auth-Request-Preferred-Username}' \
  "Caddy must pass only its post-OIDC username to FreshRSS over FastCGI."
if [[ ! -f modules/freshrss/reconcile-http-auth.php ]]; then
  echo "❌ FreshRSS must reconcile first-login registration in persisted config.php."
  exit 1
fi
forbid_match modules/freshrss/services.nix 'authType = "none"|services[.]nginx|127[.]0[.]0[.]1|ports[.]freshrss' \
  "FreshRSS must not disable authentication or expose a separately reachable HTTP origin."
forbid_match modules/freshrss/services.nix 'Content-Security-Policy' \
  "Caddy must preserve FreshRSS's application-owned Content Security Policy."
require_fixed modules/Core_Modules/homepage/services.nix 'id = "feeds";' \
  "Homepage must advertise the enabled FreshRSS web application."
require_fixed modules/Core_Modules/homepage/canary.nix 'id = "feeds"; name = "Feeds";' \
  "The authenticated canary must cover the FreshRSS route."
if [[ ! -f custom_apps/node/apps/homepage/public/logos/freshrss.svg ]]; then
  echo "❌ Homepage must package the FreshRSS logo locally."
  exit 1
fi
require_fixed custom_apps/node/apps/homepage/public/logos/freshrss.svg '#F97937' \
  "Homepage must use the orange FreshRSS logo supplied by the operator."
forbid_match custom_apps/node/apps/homepage/public/logos/freshrss.svg '#0062BE' \
  "The old blue FreshRSS logo must not remain on the Homepage card."

username_json="$(nix eval --impure --json --expr '
  let
    username = import ./modules/freshrss/username.nix;
    repeated = count: builtins.concatStringsSep "" (builtins.genList (_: "a") count);
  in {
    oneCharacter = username.valid "a";
    oneUnderscore = username.valid "_";
    punctuation = username.valid "user.name@example-test";
    thirtyNine = username.valid (repeated 39);
    forty = username.valid (repeated 40);
    slash = username.valid "user/name";
  }
')"
jq -e '
  . == {
    oneCharacter: true,
    oneUnderscore: false,
    punctuation: true,
    thirtyNine: true,
    forty: false,
    slash: false
  }
' <<<"$username_json" >/dev/null || {
  echo "❌ FreshRSS username validation does not match the upstream 1-39 character account format."
  jq . <<<"$username_json"
  exit 1
}

host="$(test_default_host)"
homepage_config="$(
  nix build --impure --no-link --print-out-paths --expr "
    let f = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
    in f.nixosConfigurations.${host}.config.systemd.services.homepage.environment.HOMEPAGE_CONFIG_FILE
  "
)"
jq -e '
  .services[]
  | select(.id == "feeds")
  | .name == "Feeds"
    and .enabled
    and .url == "https://rss.sydneybasiniot.org"
    and .logoUrl == "/logos/freshrss.svg"
    and .appName == "freshrss"
    and .requiredAnyGroups == ["freshrss-users"]
' "$homepage_config" >/dev/null || {
  echo "❌ Homepage must publish an enabled FreshRSS service card with the orange local logo and exact RSS hostname."
  exit 1
}

freshrss_json="$(NIXHOMESERVER_TEST_HOST="$host" flake_eval_json '
  hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  base = builtins.getAttr hostName f.nixosConfigurations;
  vars = builtins.getAttr hostName f.lib.nixhomeserverSettings;
  cfg = base.config;
  disabled = (base.extendModules {
    modules = [{ repo.freshrss.enable = lib.mkForce false; }];
  }).config;
  rssHost = "rss.${vars.domain}";
  serviceNames = [ "freshrss-config" "freshrss-updater" "phpfpm-freshrss" ];
in {
  registered = cfg.nixhomeserver.modules.freshrss or false;
  enabled = cfg.services.freshrss.enable;
  packageVersion = cfg.services.freshrss.package.version;
  authType = cfg.services.freshrss.authType;
  databaseType = cfg.services.freshrss.database.type;
  defaultUser = cfg.services.freshrss.defaultUser;
  expectedDefaultUser = vars.kanidmAdminUser;
  expectedHost = "rss.${vars.domain}";
  packagePath = toString cfg.services.freshrss.package;
  baseUrl = cfg.services.freshrss.baseUrl;
  apiEnabled = cfg.services.freshrss.api.enable;
  dataDir = cfg.services.freshrss.dataDir;
  webserver = cfg.services.freshrss.webserver;
  virtualHost = cfg.services.freshrss.virtualHost;
  nginxEnabled = cfg.services.nginx.enable;
  freshrssPortPresent = builtins.hasAttr "freshrss" vars.networking.ports;
  phpPoolSettings = cfg.services.phpfpm.pools.freshrss.settings;
  phpPoolSocket = cfg.services.phpfpm.pools.freshrss.socket;
  phpPackage = toString cfg.services.phpfpm.phpPackage;
  configServiceScript = cfg.systemd.services.freshrss-config.script;
  configServiceUser = cfg.systemd.services.freshrss-config.serviceConfig.User;
  caddyPackage = toString cfg.services.caddy.package;
  caddyConfig = cfg.services.caddy.virtualHosts.${rssHost}.extraConfig;
  protectedApp = cfg.repo.authGateway.protectedApps.freshrss;
  privateDnsTarget = cfg.services.unbound.privateHosts.${rssHost}.target or null;
  cloudflarePresent = builtins.hasAttr rssHost cfg.services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress;
  accessGroupMembers = cfg.services.kanidm.provision.groups."freshrss-users".members;
  expectedAccessGroupMembers = vars.kanidmAppUsers;
  accessGroupDescribed = cfg.nixhomeserver.kanidmGroupDescriptions."freshrss-users" or null;
  gatewayScopes = cfg.services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps."freshrss-users" or [ ];
  persistence = cfg.repo.impermanence.inventory.persistenceDirectories;
  impermanenceEnabled = cfg.repo.impermanence.enablePersistence;
  persistenceBindMount = builtins.any
    (mount: (mount.where or null) == "/var/lib/freshrss" && (mount.what or null) == "/persist/var/lib/freshrss")
    cfg.systemd.mounts;
  backupEntries = builtins.filter (entry: entry.app == "freshrss") cfg.repo.backups.appStateEntries;
  backupPrepare = cfg.repo.backups.prepareFragments.freshrss or null;
  enabledApps = vars.enabledApps;
  disabled = {
    enabled = disabled.services.freshrss.enable;
    services = builtins.filter (name: builtins.hasAttr name disabled.systemd.services) serviceNames;
    nginxHostPresent = builtins.hasAttr rssHost disabled.services.nginx.virtualHosts;
    gatewayPresent = builtins.hasAttr "freshrss" disabled.repo.authGateway.protectedApps;
    privateDnsPresent = builtins.hasAttr rssHost disabled.services.unbound.privateHosts;
    accessGroupPresent = builtins.hasAttr "freshrss-users" disabled.services.kanidm.provision.groups;
    accessGroupDescribed = builtins.hasAttr "freshrss-users" disabled.nixhomeserver.kanidmGroupDescriptions;
    gatewayScopePresent = builtins.hasAttr "freshrss-users" disabled.services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps;
    backupPresent = builtins.any (entry: entry.app == "freshrss") disabled.repo.backups.appStateEntries;
    backupPreparePresent = builtins.hasAttr "freshrss" disabled.repo.backups.prepareFragments;
    persistenceRetained = builtins.elem "/var/lib/freshrss" disabled.repo.impermanence.inventory.persistenceDirectories;
  };
}
')"

jq -e '
  .registered
  and .enabled
  and (.packageVersion | test("^[0-9]+[.][0-9]+"))
  and (.authType == "http_auth")
  and (.databaseType == "sqlite")
  and (.defaultUser == .expectedDefaultUser)
  and (.expectedHost == "rss.sydneybasiniot.org")
  and (.baseUrl == "https://rss.sydneybasiniot.org")
  and .apiEnabled
  and (.dataDir == "/var/lib/freshrss")
  and (.webserver == "caddy")
  and (.virtualHost == .expectedHost)
  and (.nginxEnabled == false)
  and (.freshrssPortPresent == false)
  and (.phpPoolSocket == "/run/phpfpm/freshrss.sock")
  and (.configServiceUser == "freshrss")
  and (.configServiceScript | contains("reconcile-http-auth.php"))
  and ((.configServiceScript | index("cli/reconfigure.php")) < (.configServiceScript | index("reconcile-http-auth.php")))
  and (.phpPoolSettings."listen.owner" == "caddy")
  and (.phpPoolSettings."listen.group" == "caddy")
  and (.phpPoolSettings."listen.mode" == "0600")
  and (.caddyConfig | contains("request_header -X-Forwarded-Preferred-Username"))
  and (.caddyConfig | contains("header_regexp X-Auth-Request-Groups"))
  and (.caddyConfig | contains("php_fastcgi unix//run/phpfpm/freshrss.sock"))
  and (.caddyConfig | contains("env REMOTE_USER {http.request.header.X-Auth-Request-Preferred-Username}"))
  and (.caddyConfig | contains("request_header -Remote-User"))
  and (.caddyConfig | contains("request_header -X-WebAuth-User"))
  and (.caddyConfig | contains("request_header -Remote_User"))
  and (.caddyConfig | contains("request_header -X_WebAuth_User"))
  and (.caddyConfig | contains("@native_auth_freshrss path /api/greader.php /api/greader.php/*"))
  and ((.caddyConfig | index("request_header -X-WebAuth-User")) < (.caddyConfig | index("@native_auth_freshrss path /api/greader.php /api/greader.php/*")))
  and ((.caddyConfig | index("@native_auth_freshrss path /api/greader.php /api/greader.php/*")) < (.caddyConfig | index("forward_auth http://")))
  and (.caddyConfig | contains("Strict-Transport-Security"))
  and (.caddyConfig | contains("X-Content-Type-Options"))
  and (.caddyConfig | contains("X-Frame-Options"))
  and (.caddyConfig | contains("Permissions-Policy"))
  and (.protectedApp.host == .expectedHost)
  and (.protectedApp.upstream == null)
  and (.protectedApp.authenticatedCaddyConfig | contains("php_fastcgi unix//run/phpfpm/freshrss.sock"))
  and (.protectedApp.allowedGroups == ["freshrss-users"])
  and (.protectedApp.apiUnauthenticated401 == false)
  and (.protectedApp.nativeAuthPaths == ["/api/greader.php", "/api/greader.php/*"])
  and (.protectedApp.nativeAuthCaddyConfig | contains(">Cache-Control \"no-store\""))
  and (.protectedApp.nativeAuthCaddyConfig | contains("php_fastcgi unix//run/phpfpm/freshrss.sock"))
  and ((.protectedApp.nativeAuthCaddyConfig | contains("REMOTE_USER")) | not)
  and ((.protectedApp.nativeAuthCaddyConfig | contains("X-Auth-Request")) | not)
  and (.privateDnsTarget == "private")
  and (.cloudflarePresent == false)
  and (.accessGroupMembers == .expectedAccessGroupMembers)
  and (.accessGroupDescribed | contains("FreshRSS"))
  and (.gatewayScopes == ["openid", "profile", "email", "groups_name"])
  and (.persistence | index("/var/lib/freshrss") != null)
  and .impermanenceEnabled
  and .persistenceBindMount
  and (.backupEntries == [{
    app: "freshrss",
    component: "app",
    stateRoot: "/var/lib/freshrss",
    payloadRoots: [],
    notes: "FreshRSS system configuration, per-user settings, subscriptions, and SQLite databases."
  }])
  and (.backupPrepare | contains("cli/db-backup.php --quiet"))
  and (.enabledApps | index("freshrss") != null)
  and (.disabled == {
    enabled: false,
    services: [],
    nginxHostPresent: false,
    gatewayPresent: false,
    privateDnsPresent: false,
    accessGroupPresent: false,
    accessGroupDescribed: false,
    gatewayScopePresent: false,
    backupPresent: false,
    backupPreparePresent: false,
    persistenceRetained: true
  })
' <<<"$freshrss_json" >/dev/null || {
  echo "❌ FreshRSS is missing its private OIDC route, trusted identity mapping, durable state, backup inventory, or clean disable behavior."
  jq . <<<"$freshrss_json"
  exit 1
}

freshrss_package="$(jq -er .packagePath <<<"$freshrss_json")"
require_fixed "$freshrss_package/config.default.php" "'http_auth_auto_register' => true" \
  "The pinned FreshRSS release must auto-create unknown HTTP-auth users on first login."
require_fixed "$freshrss_package/config.default.php" "'http_auth_auto_register_email_field' => ''" \
  "FreshRSS auto-registration must not substitute an email field for the authenticated username."
if rg -q 'X-Auth-Request-Email|REMOTE_USER_EMAIL' \
  <<<"$(jq -r .protectedApp.authenticatedCaddyConfig <<<"$freshrss_json")"; then
  echo "❌ FreshRSS's FastCGI identity mapping must use Kanidm preferred_username, not email."
  exit 1
fi

test_tmp="$(mktemp -d)"
trap 'rm -rf -- "$test_tmp"' EXIT
reconcile_state="$test_tmp/reconcile-state"
mkdir -p "$reconcile_state"
printf '%s\n' '<?php return [' \
  "  'salt' => 'preserve-me'," \
  "  'http_auth_auto_register' => false," \
  "  'http_auth_auto_register_email_field' => 'HTTP_X_EMAIL'," \
  '];' >"$reconcile_state/config.php"
FRESHRSS_DATA_PATH="$reconcile_state" \
  "$(jq -er .phpPackage <<<"$freshrss_json")/bin/php" \
  modules/freshrss/reconcile-http-auth.php
"$(jq -er .phpPackage <<<"$freshrss_json")/bin/php" -r '
  $config = require $argv[1];
  if (($config["salt"] ?? null) !== "preserve-me"
      || ($config["http_auth_auto_register"] ?? null) !== true
      || ($config["http_auth_auto_register_email_field"] ?? null) !== "") {
    exit(1);
  }
' "$reconcile_state/config.php" || {
  echo "❌ FreshRSS persisted config reconciliation must preserve unrelated values and enforce username-only first login."
  exit 1
}

caddy_bin="$(jq -er .caddyPackage <<<"$freshrss_json")/bin/caddy"
{
  printf '%s\n' 'rss.sydneybasiniot.org {'
  jq -r .caddyConfig <<<"$freshrss_json"
  printf '%s\n' '}'
} | "$caddy_bin" adapt --adapter caddyfile --config - | jq -e '
  ([.. | objects | select(.match? == [{"path":["/api/greader.php", "/api/greader.php/*"]}])]) as $apiRoutes
  | ($apiRoutes | length == 1)
    and ($apiRoutes[0] as $api
      | ([$api | .. | objects | .transport?.env?.REMOTE_USER? | select(. != null)] | length == 0)
      and ([$api | .. | objects | .transport?.env?.FRESHRSS_DATA_PATH? | select(. != null)] == ["/var/lib/freshrss"])
      and ([$api | .. | objects | .upstreams?[]?.dial? | select(. != null)] == ["unix//run/phpfpm/freshrss.sock"])
      and ([$api | .. | objects | .response?.set?."Cache-Control"?[]? | select(. != null)] | index("no-store") != null)
    )
    and ([.. | objects | .transport?.env?.REMOTE_USER? | select(. != null)] == ["{http.request.header.X-Auth-Request-Preferred-Username}"])
' >/dev/null || {
  echo "❌ Adapted Caddy routing must isolate native API-password requests from the OIDC REMOTE_USER path."
  exit 1
}

test_state="$test_tmp/state"
work="$test_tmp/work"
mkdir -p "$test_state/users/a" "$work/dumps" "$work/metadata"
printf '%s\n' '<?php return [];' > "$test_state/config.php"
sqlite3 "$test_state/users/a/db.sqlite" "CREATE TABLE feeds (id INTEGER PRIMARY KEY, title TEXT); INSERT INTO feeds(title) VALUES ('fixture');"

backup_fragment="$(jq -r .backupPrepare <<<"$freshrss_json")"
backup_fragment="$(sed "s|/var/lib/freshrss|$test_state|g" <<<"$backup_fragment")"
fragment_file="$test_tmp/freshrss-backup-fragment.sh"
printf '%s\n' "$backup_fragment" > "$fragment_file"

(
  set -euo pipefail
  runuser() {
    local source
    while IFS= read -r -d '' source; do
      cp -- "$source" "$(dirname "$source")/backup.sqlite"
    done < <(find "$test_state/users" -mindepth 2 -maxdepth 2 -type f -name db.sqlite -print0)
  }
  dumpsRoot="$work/dumps"
  metadataRoot="$work/metadata"
  : > "$work/metadata/SHA256SUMS"
  source "$fragment_file"
  [[ -f "$work/dumps/freshrss-a.sqlite" ]]
  [[ "$(sqlite3 -readonly "$work/dumps/freshrss-a.sqlite" 'PRAGMA integrity_check;')" == ok ]]
  (
    cd "$work"
    sha256sum --check metadata/SHA256SUMS
  ) >/dev/null
) || {
  echo "❌ FreshRSS's dynamic backup fragment failed to publish and verify a valid one-character user's SQLite backup."
  exit 1
}

echo "✅ FreshRSS OIDC module tests passed."
