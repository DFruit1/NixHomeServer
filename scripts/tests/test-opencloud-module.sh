#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"

ensure_tools jq nix rg

for required_file in \
  default.nix \
  registration.nix \
  networking.nix \
  identity.nix \
  filepaths.nix \
  services.nix \
  collabora.nix \
  webapps.nix \
  bootstrap.nix \
  backups.nix; do
  [[ -f "modules/opencloud/$required_file" ]] || {
    echo "❌ OpenCloud module is missing modules/opencloud/$required_file." >&2
    exit 1
  }
done

host="$(test_default_host)"
opencloud_json="$(
  nix eval --json ".#nixosConfigurations.${host}.config" --apply 'cfg: {
    oauth = cfg.services.kanidm.provision.systems.oauth2."opencloud-web";
    groupMembers = {
      users = cfg.services.kanidm.provision.groups."opencloud-users".members;
      admins = cfg.services.kanidm.provision.groups."opencloud-admins".members;
    };
    opencloud = {
      enable = cfg.services.opencloud.enable;
      url = cfg.services.opencloud.url;
      stateDir = cfg.services.opencloud.stateDir;
      environment = cfg.services.opencloud.environment;
      environmentFile = toString cfg.services.opencloud.environmentFile;
      guarded = cfg.repo.storage.dataPool.guardedServices;
      initReadWritePaths = map toString cfg.systemd.services.opencloud-init-config.serviceConfig.ReadWritePaths;
      initAfter = cfg.systemd.services.opencloud-init-config.after;
      serviceRequires = cfg.systemd.services.opencloud.requires;
    };
    collabora = {
      enable = cfg.services.collabora-online.enable;
      port = cfg.services.collabora-online.port;
      aliasGroups = cfg.services.collabora-online.aliasGroups;
      wopiAllow = cfg.services.collabora-online.settings.storage.wopi."@allow" or false;
      sslEnable = cfg.services.collabora-online.settings.ssl.enable or true;
      listen = cfg.services.collabora-online.settings.net.listen or "";
      proto = cfg.services.collabora-online.settings.net.proto or "";
      postAllowHosts = cfg.services.collabora-online.settings.net.post_allow.host or [];
      lokAllowHosts = cfg.services.collabora-online.settings.net.lok_allow.host or [];
      macrosEnabled = cfg.services.collabora-online.settings.security.enable_macros_execution or true;
      seccomp = cfg.services.collabora-online.settings.security.seccomp or false;
      serverSignature = cfg.services.collabora-online.settings.security.server_signature or true;
      metricsUnauthenticated = cfg.services.collabora-online.settings.security.enable_metrics_unauthenticated or true;
      adminConsole = cfg.services.collabora-online.settings.admin_console.enable or true;
      maxConcurrency = cfg.services.collabora-online.settings.per_document.max_concurrency or 0;
      limitVirtMemMb = cfg.services.collabora-online.settings.per_document.limit_virt_mem_mb or 0;
      idleTimeout = cfg.services.collabora-online.settings.per_document.idle_timeout_secs or 0;
      maxFileSize = cfg.services.collabora-online.settings.storage.wopi.max_file_size or 0;
      memproportion = cfg.services.collabora-online.settings.memproportion or 0;
    };
    caddy = builtins.attrNames cfg.services.caddy.virtualHosts;
    privateHosts = builtins.attrNames cfg.services.unbound.privateHosts;
    persistence = cfg.repo.impermanence.inventory.persistenceDirectories;
    backups = {
      apps = map (entry: entry.app) cfg.repo.backups.appStateEntries;
      criticalPaths = cfg.repo.backups.criticalPaths;
    };
  }'
)"

jq -e '
  (.opencloud.stateDir as $state
  | .opencloud.url as $url
  | ($url | sub("^https://"; "")) as $cloud
  | ($url | sub("^https://cloud\\."; "office.")) as $office
  | (.oauth.public == true)
  and (.oauth.preferShortUsername == true)
  and (.oauth.enableLocalhostRedirects == true)
  and (.oauth.originUrl | any(endswith("/oidc-callback.html")))
  and (.oauth.originUrl | any(endswith("/oidc-silent-redirect.html")))
  and (.oauth.scopeMaps."opencloud-users" | index("opencloud_roles") != null)
  and (.oauth.claimMaps.opencloud_roles.valuesByGroup."opencloud-admins" == ["opencloudAdmin"])
  and (.oauth.claimMaps.opencloud_roles.valuesByGroup."opencloud-users" == ["opencloudUser"])
  and ([.groupMembers.users[]] | length > 0)
  and (.opencloud.enable == true)
  and (.opencloud.environment.OC_INSECURE == "true")
  and (.opencloud.environment.PROXY_TLS == "false")
  and (.opencloud.environment.STORAGE_USERS_DRIVER == "posix")
  and (.opencloud.environment.OC_ADD_RUN_SERVICES == "collaboration")
  and (.opencloud.environment.OC_EXCLUDE_RUN_SERVICES == "idp")
  and (.opencloud.environment.OC_OIDC_ISSUER | contains("/oauth2/openid/opencloud-web"))
  and (.opencloud.environment.PROXY_AUTOPROVISION_ACCOUNTS == "true")
  and (.opencloud.environment.PROXY_ROLE_ASSIGNMENT_OIDC_CLAIM == "opencloud_roles")
  and (.opencloud.environment.STORAGE_USERS_POSIX_ROOT | endswith("/storage"))
  and (.opencloud.environment.COLLABORATION_WOPI_SRC | startswith("https://cloud."))
  and (.opencloud.environment.COLLABORATION_APP_ADDR | startswith("https://office."))
  and (.opencloud.environment.WEB_ASSET_APPS_PATH | startswith("/nix/store/"))
  and (.opencloud.environment.WEB_ASSET_APPS_PATH | test("opencloud-web-apps"))
  and (.opencloud.guarded | index("opencloud") != null)
  and (.opencloud.guarded | index("opencloud-storage-layout-v1") != null)
  and (.opencloud.initAfter | index("opencloud-secret-materialize.service") != null)
  and (.opencloud.serviceRequires | index("opencloud-secret-materialize.service") != null)
  and (.opencloud.initReadWritePaths | index($state) != null)
  and (.collabora.enable == true)
  and (.collabora.port == 9980)
  and (.collabora.wopiAllow == true)
  and (.collabora.sslEnable == false)
  and (.collabora.aliasGroups | length == 1)
  and (.collabora.macrosEnabled == false)
  and (.collabora.seccomp == true)
  and (.collabora.serverSignature == false)
  and (.collabora.metricsUnauthenticated == false)
  and (.collabora.adminConsole == false)
  and (.collabora.listen == "loopback")
  and (.collabora.proto == "IPv4")
  and (.collabora.postAllowHosts == ["127.0.0.1/32", "::1/128"])
  and (.collabora.lokAllowHosts == ["127.0.0.1/32", "::1/128", "localhost"])
  and (.collabora.maxConcurrency == 2)
  and (.collabora.limitVirtMemMb == 2048)
  and (.collabora.idleTimeout == 1800)
  and (.collabora.maxFileSize == 104857600)
  and (.collabora.memproportion > 0 and .collabora.memproportion < 100)
  and (.caddy | index($cloud) != null)
  and (.privateHosts | index($cloud) != null)
  and (.caddy | index($office) != null)
  and (.privateHosts | index($office) != null)
  and ([.persistence[] | if type == "string" then . else (.directory // "") end]
    | index("/var/lib/cool") != null)
  and (.backups.apps | index("opencloud") != null)
  and (.backups.criticalPaths | index($state) != null))
' <<<"$opencloud_json" >/dev/null || {
  echo "❌ Evaluated OpenCloud OIDC, PosixFS, collaboration, or wiring contract is incomplete." >&2
  jq . <<<"$opencloud_json" >&2
  exit 1
}

require_fixed modules/opencloud/services.nix \
  'STORAGE_USERS_DRIVER = "posix";' \
  "OpenCloud must default to non-collaborative PosixFS storage."
require_fixed modules/opencloud/services.nix \
  'package = unstablePkgs.opencloud;' \
  "OpenCloud must pin the nixpkgs-unstable server package."
require_fixed modules/opencloud/services.nix \
  'webPackage = unstablePkgs.opencloud.web;' \
  "OpenCloud must pin web assets to the same nixpkgs-unstable channel as the server."
require_fixed modules/opencloud/services.nix \
  'idpWebPackage = unstablePkgs.opencloud.idp-web;' \
  "OpenCloud must pin idp-web assets to the same nixpkgs-unstable channel as the server."
require_fixed modules/opencloud/filepaths.nix \
  'opencloud-storage-layout-v1' \
  "OpenCloud must provision its data-pool storage layout before starting."
require_fixed modules/opencloud/collabora.nix \
  'security.enable_macros_execution = false;' \
  "Collabora must keep document macro execution disabled."
require_fixed modules/opencloud/collabora.nix \
  'net.listen = "loopback";' \
  "Collabora must bind its HTTP port to loopback only."
require_fixed modules/opencloud/collabora.nix \
  'admin_console.enable = false;' \
  "Collabora must keep the unauthenticated admin console closed."
require_fixed modules/opencloud/webapps.nix \
  'WEB_ASSET_APPS_PATH' \
  "OpenCloud must load the pinned web app bundle from WEB_ASSET_APPS_PATH."
require_fixed modules/opencloud/webapps.nix \
  'draw-io-2.2.0.zip' \
  "OpenCloud must pin the draw.io web app bundle."
require_fixed modules/opencloud/webapps.nix \
  'unzip-2.1.0.zip' \
  "OpenCloud must pin the unzip web app bundle."
require_fixed modules/opencloud/webapps.nix \
  'json-viewer-2.1.0.zip' \
  "OpenCloud must pin the JSON viewer web app bundle."
require_fixed modules/opencloud/webapps.nix \
  '3dviewer.zip' \
  "OpenCloud must pin the 3D model viewer web app bundle."

echo "✅ OpenCloud OIDC, PosixFS storage, collaboration, and wiring checks passed."
