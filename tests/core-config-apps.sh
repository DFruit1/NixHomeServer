#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools nix jq rg python3

snapshot="$(nix_eval_host_snapshot_json '
  let
    sambaSettings = cfg.services.samba.settings;
    lanView = builtins.head (builtins.filter (view: view.name == "lan") cfg.services.unbound.settings.view);
    netbirdView = builtins.head (builtins.filter (view: view.name == "netbird") cfg.services.unbound.settings.view);
    netbirdIface = cfg.services.netbird.clients.myNetbirdClient.interface;
  in
    {
      vars = {
        hostname = vars.hostname;
        domain = vars.domain;
        dataRoot = vars.dataRoot;
        usersRoot = vars.usersRoot;
        sharedRoot = vars.sharedRoot;
        netIface = vars.netIface;
        nbIP = vars.nbIP;
        serverLanIP = vars.serverLanIP;
        serverLanPrefixLength = vars.serverLanPrefixLength;
        lanDnsDomain = vars.lanDnsDomain;
        kanidmDomain = vars.kanidmDomain;
        filesDomain = vars.filesDomain;
        emailsDomain = vars.emailsDomain;
        kavitaDomain = vars.kavitaDomain;
        photosDomain = vars.photosDomain;
        sharePhotosDomain = vars.sharePhotosDomain;
        metubeDomain = vars.metubeDomain;
        kanidmAdminUser = vars.kanidmAdminUser;
        paperlessEnableDangerousMacroOfficeParsing = vars.paperlessEnableDangerousMacroOfficeParsing;
        paperlessOcrLanguage = vars.paperlessOcrLanguage;
        userContentSubdirs = vars.userContentSubdirs;
        sharedContentSubdirs = vars.sharedContentSubdirs;
        fileAccessPosixGids = vars.fileAccessPosixGids;
      };
      config = {
        immichExternalDomain = cfg.services.immich.settings.server.externalDomain;
        immichOauthMobileOverrideEnabled = cfg.services.immich.settings.oauth.mobileOverrideEnabled;
        immichOauthMobileRedirectUri = cfg.services.immich.settings.oauth.mobileRedirectUri;
        immichOauthOrigins = cfg.services.kanidm.provision.systems.oauth2.immich-web.originUrl;
        caddyHosts = builtins.attrNames cfg.services.caddy.virtualHosts;
        cloudflaredIngressHosts = builtins.attrNames cfg.services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress;
        unboundInterfaces = cfg.services.unbound.settings.server.interface;
        lanViewLocalZones = lanView."local-zone";
        lanViewLocalData = lanView."local-data";
        netbirdViewLocalData = netbirdView."local-data";
        unboundAccessControl = cfg.services.unbound.settings.server.access-control;
        unboundAccessControlView = cfg.services.unbound.settings.server.access-control-view;
        unboundForwardAddresses = (builtins.head cfg.services.unbound.settings."forward-zone")."forward-addr";
        dnscryptIgnoreSystemDns = cfg.services.dnscrypt-proxy.settings.ignore_system_dns;
        dnscryptBootstrapResolvers = cfg.services.dnscrypt-proxy.settings.bootstrap_resolvers;
        dnscryptSources = builtins.attrNames cfg.services.dnscrypt-proxy.settings.sources;
        sambaSettings = sambaSettings;
        sambaSettingsKeys = builtins.attrNames sambaSettings;
        sambaInterfaces = sambaSettings.global.interfaces;
        sambaHostsAllow = sambaSettings.global."hosts allow";
        sambaPersonalPath = sambaSettings.personal.path;
        sambaPersonalValidUsers = sambaSettings.personal."valid users";
        sambaSharedPath = sambaSettings.shared.path;
        sambaSharedValidUsers = sambaSettings.shared."valid users";
        sambaSharedWriteList = sambaSettings.shared."write list";
        sambaSharedInheritAcls = sambaSettings.shared."inherit acls";
        sambaSharedCreateMask = sambaSettings.shared."create mask";
        sambaSharedForceCreateMode = sambaSettings.shared."force create mode";
        sambaSharedDirectoryMask = sambaSettings.shared."directory mask";
        sambaSharedForceDirectoryMode = sambaSettings.shared."force directory mode";
        podmanEnable = cfg.virtualisation.podman.enable;
        manageLingering = cfg.users.manageLingering;
        immichProxyUserIsSystemUser = cfg.users.users."immich-public-proxy".isSystemUser;
        immichProxyUserLinger = cfg.users.users."immich-public-proxy".linger;
        hasImmichProxyQuadlet = cfg.environment.etc ? "containers/systemd/users/3001/immich-public-proxy.container";
        immichProxyQuadlet = cfg.environment.etc."containers/systemd/users/3001/immich-public-proxy.container".text;
        metubeUserIsSystemUser = cfg.users.users.metube.isSystemUser;
        metubeUserLinger = cfg.users.users.metube.linger;
        metubeUserExtraGroups = cfg.users.users.metube.extraGroups;
        hasMetubeQuadlet = cfg.environment.etc ? "containers/systemd/users/3002/metube.container";
        metubeQuadlet = cfg.environment.etc."containers/systemd/users/3002/metube.container".text;
        metubeScopeMap = cfg.services.kanidm.provision.systems.oauth2."metube-web".scopeMaps."metube-users";
        lanAllowedTcpPorts = cfg.networking.firewall.interfaces.${vars.netIface}.allowedTCPPorts;
        netbirdIface = netbirdIface;
        netbirdAllowedTcpPorts = cfg.networking.firewall.interfaces.${netbirdIface}.allowedTCPPorts;
        powerGovernor = cfg.powerManagement.cpuFreqGovernor;
        nightlySuspendTimer = cfg.systemd.timers.power-management-nightly-suspend.timerConfig.OnCalendar;
        mailArchivePort = cfg.services.mail-archive-ui.port;
        mailArchiveDataDir = cfg.services.mail-archive-ui.dataDir;
        mailArchiveAccountStateRoot = cfg.services.mail-archive-ui.accountStateRoot;
        mailArchivePaperlessConsumeRoot = cfg.services.mail-archive-ui.environment.MAIL_ARCHIVE_UI_PAPERLESS_CONSUME_ROOT;
        mailArchivePaperlessStagingDir = cfg.services.mail-archive-ui.environment.MAIL_ARCHIVE_UI_PAPERLESS_STAGING_DIR;
        paperlessDataDir = cfg.services.paperless.dataDir;
        paperlessConfigureTika = cfg.services.paperless.configureTika;
        paperlessExporterEnable = cfg.services.paperless.exporter.enable;
        paperlessExporterDirectory = cfg.services.paperless.exporter.directory;
        paperlessExporterOnCalendar = cfg.services.paperless.exporter.onCalendar;
        paperlessOcrLanguage = cfg.services.paperless.settings.PAPERLESS_OCR_LANGUAGE;
        paperlessOcrClean = cfg.services.paperless.settings.PAPERLESS_OCR_CLEAN;
        paperlessOcrOutputType = cfg.services.paperless.settings.PAPERLESS_OCR_OUTPUT_TYPE;
        paperlessConsumerInotifyDelay = cfg.services.paperless.settings.PAPERLESS_CONSUMER_INOTIFY_DELAY;
        paperlessIgnorePatterns = cfg.services.paperless.settings.PAPERLESS_CONSUMER_IGNORE_PATTERNS;
        paperlessConsumerRecursive = cfg.services.paperless.settings.PAPERLESS_CONSUMER_RECURSIVE;
        paperlessConsumerSubdirsAsTags = cfg.services.paperless.settings.PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS;
        paperlessSocialAccountDefaultGroups = cfg.services.paperless.settings.PAPERLESS_SOCIAL_ACCOUNT_DEFAULT_GROUPS;
        hasLegacyPaperlessSocialDefaultGroups = cfg.services.paperless.settings ? PAPERLESS_SOCIAL_DEFAULT_GROUPS;
        paperlessOidcEnvScript = cfg.systemd.services.paperless-oidc-env.script;
        kavitaDataDir = cfg.services.kavita.dataDir;
        kavitaDisablePasswordAuthentication = cfg.services.kavita.settings.OpenIdConnectSettings.DisablePasswordAuthentication;
        jellyfinDataDir = cfg.services.jellyfin.dataDir;
        audiobookshelfExtraGroups = cfg.users.users.audiobookshelf.extraGroups;
        kavitaExtraGroups = cfg.users.users.kavita.extraGroups;
        jellyfinExtraGroups = cfg.users.users.jellyfin.extraGroups;
        hasAudiobookshelfTimer = cfg.systemd.timers ? "audiobookshelf-library-sync-v1";
        hasKavitaTimer = cfg.systemd.timers ? "kavita-library-sync-v1";
        hasJellyfinTimer = cfg.systemd.timers ? "jellyfin-reconcile-v1";
        kanidmProvisionGroups = cfg.services.kanidm.provision.groups;
        kanidmInstanceUrl = cfg.services.kanidm.provision.instanceUrl;
        audiobookshelfWorkingDirectory = cfg.systemd.services.audiobookshelf.serviceConfig.WorkingDirectory;
        hasAudiobookshelfService = cfg.systemd.services ? "audiobookshelf-library-sync-v1";
        hasKavitaService = cfg.systemd.services ? "kavita-library-sync-v1";
        hasJellyfinService = cfg.systemd.services ? "jellyfin-reconcile-v1";
        hasAppStateMigrationService = cfg.systemd.services ? "app-state-migration-v1";
        hasKanidmFilesPosixGroupsService = cfg.systemd.services ? "kanidm-files-posix-groups";
        hasSharedFilesAccessSyncService = cfg.systemd.services ? "shared-files-access-sync";
        hasCopypartyRuntimeConfigSyncService = cfg.systemd.services ? "copyparty-runtime-config-sync";
        kanidmFilesPosixGroupsScript = cfg.systemd.services.kanidm-files-posix-groups.script;
        sharedFilesAccessSyncScript = cfg.systemd.services.shared-files-access-sync.script;
        mailArchiveSyncConditionMount = cfg.systemd.services.mail-archive-sync.unitConfig.ConditionPathIsMountPoint;
        mailArchiveUiUmask = cfg.systemd.services.mail-archive-ui.serviceConfig.UMask;
        mailArchiveUiReadWritePaths = cfg.systemd.services.mail-archive-ui.serviceConfig.ReadWritePaths;
        mailArchiveSyncUmask = cfg.systemd.services.mail-archive-sync.serviceConfig.UMask;
        mailArchiveUiPath = cfg.systemd.services.mail-archive-ui.path;
        mailArchiveSyncTimer = cfg.systemd.timers.mail-archive-sync.timerConfig.OnCalendar;
        kanidmPamAllowedLoginGroups = cfg.services.kanidm.unixSettings.pam_allowed_login_groups;
        oauth2ProxyScope = cfg.services.oauth2-proxy.scope;
        oauth2ProxyAllowedGroups = cfg.services.oauth2-proxy.extraConfig."allowed-group";
      };
    }
')"

snapshot_query() {
  jq -c "$1" <<<"$snapshot"
}

danger_query() {
  jq -c "$1" <<<"$danger_snapshot"
}

danger_snapshot="$(
  NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}" \
    nix eval --json --impure --expr "
      let
        flake = builtins.getFlake (toString ${TESTS_REPO_ROOT});
        lib = flake.inputs.nixpkgs.lib;
        system = \"x86_64-linux\";
        vars = (import ${TESTS_REPO_ROOT}/vars.nix { inherit lib; }) // {
          paperlessEnableDangerousMacroOfficeParsing = true;
        };
        cfg = lib.nixosSystem {
          inherit system;
          modules = [
            ${TESTS_REPO_ROOT}/hardware-configuration.nix
            ${TESTS_REPO_ROOT}/configuration.nix
            flake.inputs.agenix.nixosModules.default
            flake.inputs.disko.nixosModules.disko
            flake.inputs.impermanence.nixosModules.impermanence
          ];
          specialArgs = {
            inherit vars;
            self = flake;
            disko = flake.inputs.disko;
            copyparty = flake.inputs.copyparty;
            pkgsUnstable = flake.inputs.nixpkgs-unstable.legacyPackages.\${system};
          };
        };
      in
        {
          paperlessIgnorePatterns = cfg.config.services.paperless.settings.PAPERLESS_CONSUMER_IGNORE_PATTERNS;
        }
    "
)"

lan_prefix_length="$(snapshot_query '.vars.serverLanPrefixLength' | jq -r .)"
server_lan_ip="$(snapshot_query '.vars.serverLanIP' | jq -r .)"
expected_lan_cidr="$(
  python3 - "$server_lan_ip" "$lan_prefix_length" <<'PY'
import ipaddress
import sys

server_ip = sys.argv[1]
prefix = int(sys.argv[2])
network = ipaddress.ip_network(f"{server_ip}/{prefix}", strict=False)
print(network.with_prefixlen)
PY
)"

echo "ℹ️ Checking app routing and service exposure…"
require_json_equal "$(snapshot_query '.config.immichExternalDomain')" "\"https://$(snapshot_query '.vars.sharePhotosDomain' | jq -r .)\"" \
  "Immich public share links must point at the share proxy hostname."
require_json_equal "$(snapshot_query '.config.immichOauthMobileOverrideEnabled')" 'true' \
  "Immich must enable the HTTPS mobile redirect override."
require_json_equal "$(snapshot_query '.config.immichOauthMobileRedirectUri')" "\"https://$(snapshot_query '.vars.photosDomain' | jq -r .)/api/oauth/mobile-redirect\"" \
  "Immich must use the documented HTTPS mobile redirect override path."
require_json_contains "$(snapshot_query '.config.immichOauthOrigins')" "https://$(snapshot_query '.vars.photosDomain' | jq -r .)/auth/login" \
  "Kanidm must allow Immich web login redirects."
require_json_contains "$(snapshot_query '.config.immichOauthOrigins')" "https://$(snapshot_query '.vars.photosDomain' | jq -r .)/user-settings" \
  "Kanidm must allow Immich web account-linking redirects."
require_json_contains "$(snapshot_query '.config.immichOauthOrigins')" "https://$(snapshot_query '.vars.photosDomain' | jq -r .)/api/oauth/mobile-redirect" \
  "Kanidm must allow the Immich HTTPS mobile redirect override."
require_fixed modules/immich/service.nix 'vars.immichManagedRoot' \
  "Immich must derive its managed library under vars.immichRoot."

caddy_hosts="$(snapshot_query '.config.caddyHosts')"
require_json_contains "$caddy_hosts" "$(snapshot_query '.vars.kanidmDomain' | jq -r .)" \
  "Caddy must serve the Kanidm hostname."
require_json_contains "$caddy_hosts" "$(snapshot_query '.vars.filesDomain' | jq -r .)" \
  "Caddy must serve files.<domain>."
require_json_contains "$caddy_hosts" "$(snapshot_query '.vars.emailsDomain' | jq -r .)" \
  "Caddy must serve emails.<domain>."
require_json_contains "$caddy_hosts" "$(snapshot_query '.vars.kavitaDomain' | jq -r .)" \
  "Caddy must serve books.<domain>."
require_json_contains "$caddy_hosts" "$(snapshot_query '.vars.photosDomain' | jq -r .)" \
  "Caddy must serve the private Immich hostname."
require_json_contains "$caddy_hosts" "$(snapshot_query '.vars.sharePhotosDomain' | jq -r .)" \
  "Caddy must serve the public Immich share-proxy hostname."
require_json_contains "$caddy_hosts" "$(snapshot_query '.vars.metubeDomain' | jq -r .)" \
  "Caddy must serve the private MeTube hostname."
forbid_json_contains "$caddy_hosts" "photo.$(snapshot_query '.vars.domain' | jq -r .)" \
  "Caddy must not retain the legacy photo hostname."
forbid_json_contains "$caddy_hosts" "mail.$(snapshot_query '.vars.domain' | jq -r .)" \
  "Caddy must not retain the legacy mail hostname."
forbid_json_contains "$caddy_hosts" "book.$(snapshot_query '.vars.domain' | jq -r .)" \
  "Caddy must not retain the legacy book hostname."

cloudflared_ingress_hosts="$(snapshot_query '.config.cloudflaredIngressHosts')"
require_json_contains "$cloudflared_ingress_hosts" "$(snapshot_query '.vars.sharePhotosDomain' | jq -r .)" \
  "Cloudflared must publish the public share-proxy hostname."
forbid_json_contains "$cloudflared_ingress_hosts" "$(snapshot_query '.vars.photosDomain' | jq -r .)" \
  "Cloudflared must not publish the private Immich hostname."
forbid_json_contains "$cloudflared_ingress_hosts" "$(snapshot_query '.vars.metubeDomain' | jq -r .)" \
  "Cloudflared must not publish the private MeTube hostname."

if ! rg -F 'privateHostedRecords vars.serverLanIP' modules/Core_Modules/unbound/default.nix >/dev/null; then
  echo "❌ Unbound must still derive split-horizon LAN records from vars.serverLanIP."
  exit 1
fi

unbound_interfaces="$(snapshot_query '.config.unboundInterfaces')"
require_json_contains "$unbound_interfaces" "127.0.0.1" \
  "Unbound must listen on localhost for server-local recursion."
require_json_contains "$unbound_interfaces" "$(snapshot_query '.vars.nbIP' | jq -r .)" \
  "Unbound must listen on the NetBird address."
require_json_contains "$unbound_interfaces" "$(snapshot_query '.vars.serverLanIP' | jq -r .)" \
  "Unbound must listen on the primary LAN address in split-horizon mode."

lan_view_local_zones="$(jq -r '.config.lanViewLocalZones | join("\n")' <<<"$snapshot")"
lan_view_local_data="$(jq -r '.config.lanViewLocalData | join("\n")' <<<"$snapshot")"
require_json_contains "$(jq -Rs . <<<"$lan_view_local_zones")" "$(snapshot_query '.vars.lanDnsDomain' | jq -r .) static" \
  "The LAN Unbound view must serve the LAN-only DNS zone."
require_json_contains "$(jq -Rs . <<<"$lan_view_local_data")" "$(snapshot_query '.vars.hostname' | jq -r .).$(snapshot_query '.vars.lanDnsDomain' | jq -r .)" \
  "The LAN Unbound view must publish the server LAN hostname."
require_json_contains "$(jq -Rs . <<<"$lan_view_local_data")" "router.$(snapshot_query '.vars.lanDnsDomain' | jq -r .)" \
  "The LAN Unbound view must publish the router LAN hostname."
require_json_contains "$(jq -Rs . <<<"$lan_view_local_data")" "$(snapshot_query '.vars.metubeDomain' | jq -r .)" \
  "The LAN Unbound view must publish the private MeTube hostname."
require_json_contains "$(jq -Rs . <<<"$lan_view_local_data")" "$(snapshot_query '.vars.kanidmDomain' | jq -r .)" \
  "The LAN Unbound view must publish the private Kanidm hostname."
require_json_contains "$(jq -Rs . <<<"$lan_view_local_data")" "$(snapshot_query '.vars.emailsDomain' | jq -r .)" \
  "The LAN Unbound view must publish the private emails hostname."
require_json_contains "$(jq -Rs . <<<"$lan_view_local_data")" "$(snapshot_query '.vars.kavitaDomain' | jq -r .)" \
  "The LAN Unbound view must publish the private books hostname."
require_json_contains "$(jq -Rs . <<<"$lan_view_local_data")" "$(snapshot_query '.vars.filesDomain' | jq -r .)" \
  "The LAN Unbound view must publish the private files hostname."
forbid_json_contains "$(jq -Rs . <<<"$lan_view_local_data")" "mail.$(snapshot_query '.vars.domain' | jq -r .)" \
  "The LAN Unbound view must not retain the legacy mail hostname."
forbid_json_contains "$(jq -Rs . <<<"$lan_view_local_data")" "book.$(snapshot_query '.vars.domain' | jq -r .)" \
  "The LAN Unbound view must not retain the legacy book hostname."
require_json_contains "$(jq -Rs . <<<"$lan_view_local_data")" 'PTR' \
  "The LAN Unbound view must include reverse DNS records for LAN hosts."

netbird_view_local_data="$(jq -r '.config.netbirdViewLocalData | join("\n")' <<<"$snapshot")"
require_json_contains "$(jq -Rs . <<<"$netbird_view_local_data")" "$(snapshot_query '.vars.metubeDomain' | jq -r .)" \
  "The NetBird Unbound view must publish the private MeTube hostname."
require_json_contains "$(jq -Rs . <<<"$netbird_view_local_data")" "$(snapshot_query '.vars.emailsDomain' | jq -r .)" \
  "The NetBird Unbound view must publish the private emails hostname."
require_json_contains "$(jq -Rs . <<<"$netbird_view_local_data")" "$(snapshot_query '.vars.kavitaDomain' | jq -r .)" \
  "The NetBird Unbound view must publish the private books hostname."
forbid_json_contains "$(jq -Rs . <<<"$netbird_view_local_data")" "$(snapshot_query '.vars.kanidmDomain' | jq -r .)" \
  "The NetBird Unbound view must leave the public Kanidm hostname on normal recursion."
forbid_json_contains "$(jq -Rs . <<<"$netbird_view_local_data")" "$(snapshot_query '.vars.filesDomain' | jq -r .)" \
  "The NetBird Unbound view must leave the public files hostname on normal recursion."
forbid_json_contains "$(jq -Rs . <<<"$netbird_view_local_data")" "mail.$(snapshot_query '.vars.domain' | jq -r .)" \
  "The NetBird Unbound view must not retain the legacy mail hostname."
forbid_json_contains "$(jq -Rs . <<<"$netbird_view_local_data")" "book.$(snapshot_query '.vars.domain' | jq -r .)" \
  "The NetBird Unbound view must not retain the legacy book hostname."

unbound_access_control="$(snapshot_query '.config.unboundAccessControl')"
require_json_contains "$unbound_access_control" "${expected_lan_cidr} allow" \
  "Unbound must only trust the configured LAN subnet."
forbid_json_contains "$unbound_access_control" "192.168.0.0/16 allow" \
  "Unbound must not trust the whole RFC1918 /16 by default."
unbound_access_control_view="$(snapshot_query '.config.unboundAccessControlView')"
require_json_contains "$unbound_access_control_view" "${expected_lan_cidr} lan" \
  "Unbound split-horizon access-control views must follow the configured LAN subnet."
forbid_json_contains "$unbound_access_control_view" "192.168.0.0/16 lan" \
  "Unbound split-horizon views must not trust the whole RFC1918 /16 by default."

unbound_forward_addresses="$(snapshot_query '.config.unboundForwardAddresses')"
require_json_contains "$unbound_forward_addresses" '127.0.0.1@5053' \
  "Unbound must prefer the local dnscrypt-proxy listener for recursive forwarding."
require_json_equal "$unbound_forward_addresses" '["127.0.0.1@5053"]' \
  "Encrypted-only upstream DNS must remove the plaintext Unbound fallback resolvers."
require_json_equal "$(snapshot_query '.config.dnscryptIgnoreSystemDns')" 'true' \
  "dnscrypt-proxy must ignore the host resolver while bootstrapping."
require_json_contains "$(snapshot_query '.config.dnscryptBootstrapResolvers')" '9.9.9.9:53' \
  "dnscrypt-proxy must keep the first explicit bootstrap resolver."
require_json_contains "$(snapshot_query '.config.dnscryptBootstrapResolvers')" '1.1.1.1:53' \
  "dnscrypt-proxy must keep the second explicit bootstrap resolver."
forbid_json_contains "$(snapshot_query '.config.dnscryptSources')" 'relays' \
  "dnscrypt-proxy must not retain the unused relay metadata source."

echo "ℹ️ Checking SMB and rootless container exposure…"
require_json_equal "$(snapshot_query '.config.sambaInterfaces')" "\"lo $(snapshot_query '.vars.netIface' | jq -r .)\"" \
  "Samba must bind only to localhost and the primary LAN interface."
require_json_equal "$(snapshot_query '.config.sambaHostsAllow')" "\"$(snapshot_query '.vars.serverLanIP' | jq -r .)/$(snapshot_query '.vars.serverLanPrefixLength' | jq -r .) 127.0.0.1\"" \
  "Samba hosts-allow rules must be restricted to the LAN prefix plus localhost."
require_json_equal "$(snapshot_query '.config.sambaPersonalPath')" "\"$(snapshot_query '.vars.usersRoot' | jq -r .)/%U\"" \
  "The personal SMB share must resolve each user to their own content root."
require_json_equal "$(snapshot_query '.config.sambaPersonalValidUsers')" '"@user-files"' \
  "The personal SMB share must be gated only to the personal file-access group."
require_json_equal "$(snapshot_query '.config.sambaSharedPath')" "$(snapshot_query '.vars.sharedRoot')" \
  "The shared SMB share must expose only the shared content root."
require_json_equal "$(snapshot_query '.config.sambaSharedValidUsers')" '"@shared-files-ro @shared-files-rw"' \
  "The shared SMB share must be gated to the shared-access groups."
require_json_equal "$(snapshot_query '.config.sambaSharedWriteList')" '"@shared-files-rw"' \
  "The shared SMB share must reserve write access for the read-write shared group."
require_json_equal "$(snapshot_query '.config.sambaSharedInheritAcls')" '"yes"' \
  "The shared SMB share must inherit filesystem ACLs."
require_json_equal "$(snapshot_query '.config.sambaSharedCreateMask')" '"0640"' \
  "The shared SMB share must create files without peer write bits."
require_json_equal "$(snapshot_query '.config.sambaSharedForceCreateMode')" '"0640"' \
  "The shared SMB share must force non-overwritable file modes."
require_json_equal "$(snapshot_query '.config.sambaSharedDirectoryMask')" '"2750"' \
  "The shared SMB share must create setgid directories with no peer write bits."
require_json_equal "$(snapshot_query '.config.sambaSharedForceDirectoryMode')" '"2750"' \
  "The shared SMB share must force shared directories into the constrained ACL model."
require_json_contains "$(snapshot_query '.config.lanAllowedTcpPorts')" "139" \
  "The LAN interface must allow SMB port 139."
require_json_contains "$(snapshot_query '.config.lanAllowedTcpPorts')" "445" \
  "The LAN interface must allow SMB port 445."
forbid_json_contains "$(snapshot_query '.config.netbirdAllowedTcpPorts')" "139" \
  "The NetBird interface must not allow SMB port 139."
forbid_json_contains "$(snapshot_query '.config.netbirdAllowedTcpPorts')" "445" \
  "The NetBird interface must not allow SMB port 445."
require_json_contains "$(snapshot_query '.config.sambaSettingsKeys')" "personal" \
  "Samba must expose the dedicated personal share."
require_json_contains "$(snapshot_query '.config.sambaSettingsKeys')" "shared" \
  "Samba must expose the dedicated shared share."
forbid_json_contains "$(snapshot_query '.config.sambaSettingsKeys')" "data" \
  "Samba must not retain the old admin-wide data share."
forbid_json_contains "$(snapshot_query '.config.sambaSettingsKeys')" "homes" \
  "Samba must not retain the old homes share."
forbid_json_contains "$(snapshot_query '.config.sambaSettingsKeys')" "exchange" \
  "Samba must not retain the old exchange share."
forbid_json_contains "$(snapshot_query '.config.sambaSettingsKeys')" "public" \
  "Samba must not retain the old public share."
forbid_json_contains "$(snapshot_query '.config.sambaSettingsKeys')" "photos-upload" \
  "Samba must not retain the old photos-upload share."
forbid_json_contains "$(snapshot_query '.config.sambaSettingsKeys')" "documents-upload" \
  "Samba must not retain the old documents-upload share."

require_json_equal "$(snapshot_query '.config.podmanEnable')" 'true' \
  "Podman must be enabled for the rootless Immich share proxy."
require_json_equal "$(snapshot_query '.config.manageLingering')" 'true' \
  "NixOS must manage lingering for the rootless Immich share proxy user."
require_json_equal "$(snapshot_query '.config.immichProxyUserIsSystemUser')" 'true' \
  "The Immich share proxy must run under a dedicated system user."
require_json_equal "$(snapshot_query '.config.immichProxyUserLinger')" 'true' \
  "The Immich share proxy user must linger so its user manager starts at boot."
require_json_equal "$(snapshot_query '.config.hasImmichProxyQuadlet')" 'true' \
  "The Immich share proxy quadlet must be installed declaratively under /etc/containers/systemd/users/3001."
require_json_contains "$(snapshot_query '.config.immichProxyQuadlet')" 'DropCapability=all' \
  "The Immich share proxy quadlet must drop all Linux capabilities."
require_json_contains "$(snapshot_query '.config.immichProxyQuadlet')" 'NoNewPrivileges=true' \
  "The Immich share proxy quadlet must disable privilege escalation."
require_json_contains "$(snapshot_query '.config.immichProxyQuadlet')" 'ReadOnly=true' \
  "The Immich share proxy quadlet must mount the container root filesystem read-only."

require_json_equal "$(snapshot_query '.config.metubeUserIsSystemUser')" 'true' \
  "MeTube must run under a dedicated system user."
require_json_equal "$(snapshot_query '.config.metubeUserLinger')" 'true' \
  "The MeTube user must linger so its user manager starts at boot."
require_json_contains "$(snapshot_query '.config.metubeUserExtraGroups')" 'users' \
  "The MeTube user must keep shared-media group access."
require_json_equal "$(snapshot_query '.config.hasMetubeQuadlet')" 'true' \
  "The MeTube quadlet must be installed declaratively under /etc/containers/systemd/users/3002."
require_json_contains "$(snapshot_query '.config.metubeQuadlet')" 'DOWNLOAD_DIR=/downloads' \
  "The MeTube quadlet must mount the shared video library as /downloads."
require_json_contains "$(snapshot_query '.config.metubeQuadlet')" 'STATE_DIR=/state' \
  "The MeTube quadlet must keep queue state outside the shared media tree."
require_json_contains "$(snapshot_query '.config.metubeQuadlet')" 'TEMP_DIR=/tmp-downloads' \
  "The MeTube quadlet must keep temporary files outside the shared media tree."
require_json_contains "$(snapshot_query '.config.metubeQuadlet')" 'CUSTOM_DIRS=false' \
  "The MeTube quadlet must disable custom download directories."
require_json_contains "$(snapshot_query '.config.metubeQuadlet')" 'CREATE_CUSTOM_DIRS=false' \
  "The MeTube quadlet must prevent users from creating arbitrary directories."
require_json_contains "$(snapshot_query '.config.metubeQuadlet')" 'ALLOW_YTDL_OPTIONS_OVERRIDES=false' \
  "The MeTube quadlet must disable arbitrary per-download yt-dlp overrides."
require_json_contains "$(snapshot_query '.config.metubeQuadlet')" 'UMASK=002' \
  "The MeTube quadlet must keep shared-library group write semantics."
require_json_contains "$(snapshot_query '.config.metubeQuadlet')" 'CHOWN_DIRS=false' \
  "The MeTube quadlet must not chown the shared library root."
require_json_contains "$(snapshot_query '.config.metubeQuadlet')" 'OUTPUT_TEMPLATE=%%(channel,uploader,creator|Unknown Channel)S/%%(upload_date>%%Y,release_date>%%Y|Unknown Year)s/%%(upload_date>%%Y-%%m-%%d,release_date>%%Y-%%m-%%d|Unknown Date)s - %%(title|Unknown Title)S [%%(id|NOID)s].%%(ext)s' \
  "The MeTube quadlet must write completed videos into the channel/year/title layout."
require_json_contains "$(snapshot_query '.config.metubeQuadlet')" '\"format\":\"bestvideo[vcodec*=avc1]+bestaudio[acodec*=mp4a]/best\"' \
  "The MeTube quadlet must prefer AVC video and AAC audio."
require_json_contains "$(snapshot_query '.config.metubeQuadlet')" '\"merge_output_format\":\"mkv\"' \
  "The MeTube quadlet must merge downloads into MKV."
require_json_contains "$(snapshot_query '.config.metubeQuadlet')" '\"writethumbnail\":true' \
  "The MeTube quadlet must enable thumbnail fetching."
require_json_contains "$(snapshot_query '.config.metubeQuadlet')" '\"key\":\"FFmpegMetadata\"' \
  "The MeTube quadlet must embed metadata via yt-dlp postprocessors."
require_json_contains "$(snapshot_query '.config.metubeQuadlet')" '\"key\":\"EmbedThumbnail\"' \
  "The MeTube quadlet must embed thumbnails via yt-dlp postprocessors."
require_json_contains "$(snapshot_query '.config.metubeScopeMap')" 'groups_name' \
  "Kanidm must grant the groups_name scope to the MeTube oauth2 client."

echo "ℹ️ Checking Copyparty, mail archive, and app state…"
require_match modules/Core_Modules/caddy/default.nix '@copyparty_shares path /shares /shares/\*' \
  "Caddy must bypass oauth2-proxy only for the explicit Copyparty share namespace."
require_match modules/copyparty/default.nix 'shr = "/shares";' \
  "Copyparty must publish anonymous share links under /shares."
require_match modules/copyparty/default.nix '"shr-who" = "auth";' \
  "Copyparty share creation must be limited to authenticated users."
require_match modules/copyparty/default.nix 'r: @shared-files-ro' \
  "Copyparty shared volumes must grant read-only access to the shared read-only group."
require_match modules/copyparty/default.nix 'r: @shared-files-ro, @shared-files-rw' \
  "Copyparty shared volumes must keep both shared groups read-only."
forbid_match modules/copyparty/default.nix 'rwmda: @shared-files-rw' \
  "Copyparty shared volumes must not grant shared write access."
forbid_match modules/copyparty/default.nix 'w: @shared-files-rw|m: @shared-files-rw|d: @shared-files-rw|a: @shared-files-rw' \
  "Copyparty shared volumes must not grant write, move, delete, or admin rights to shared groups."
require_match modules/copyparty/default.nix 'kanidm group get' \
  "Copyparty must derive personal roots from live user-files membership."
require_match modules/copyparty/default.nix 'build-copyparty-runtime-config' \
  "Copyparty must build its runtime config through a dedicated helper script."
require_match modules/copyparty/default.nix 'copyparty-runtime-config-sync' \
  "Copyparty must build its runtime config in a dedicated oneshot service."
require_match modules/copyparty/default.nix '\[/\$username/files\]' \
  "Copyparty must generate per-user writable files subtrees at runtime."
require_match modules/copyparty/default.nix '\[/\$username/audiobooks\]' \
  "Copyparty must generate per-user writable audiobooks subtrees at runtime."
require_match modules/copyparty/default.nix '\[/\$username/books\]' \
  "Copyparty must generate per-user writable books subtrees at runtime."
require_match modules/copyparty/default.nix '\[/shared/files\]' \
  "Copyparty must expose a dedicated shared-files subtree."
require_match modules/copyparty/default.nix '\[/shared/audiobooks\]' \
  "Copyparty must expose a dedicated shared-audiobooks subtree."
require_match modules/copyparty/default.nix '\[/shared/books\]' \
  "Copyparty must expose a dedicated shared-books subtree."
require_match modules/copyparty/default.nix '\[/shared/videos\]' \
  "Copyparty must expose a dedicated shared-videos subtree."
forbid_match modules/copyparty/default.nix '@acct' \
  "Copyparty shared access must be controlled by explicit Kanidm groups, not the catch-all authenticated group."
forbid_match modules/copyparty/default.nix 'media-library' \
  "Copyparty must not retain the removed broad media-library group."
require_json_contains "$(snapshot_query '.vars.userContentSubdirs')" "emails" \
  "Per-user content roots must include an emails directory."
forbid_json_contains "$(snapshot_query '.vars.userContentSubdirs')" "videos" \
  "Per-user content roots must not include videos."
require_json_contains "$(snapshot_query '.vars.sharedContentSubdirs')" "emails" \
  "Shared content roots must include an emails directory."
require_json_contains "$(snapshot_query '.vars.sharedContentSubdirs')" "files" \
  "Shared content roots must include the dedicated files directory."
require_json_contains "$(snapshot_query '.vars.sharedContentSubdirs')" "videos" \
  "Shared content roots must include the shared videos directory."
forbid_json_contains "$(snapshot_query '.vars.sharedContentSubdirs')" "documents" \
  "Shared content roots must retire the shared documents directory."
forbid_json_contains "$(snapshot_query '.vars.sharedContentSubdirs')" "photos" \
  "Shared content roots must retire the shared photos directory."
require_match modules/copyparty/default.nix '\[/shared/emails\]' \
  "Copyparty must expose shared mail archives as a dedicated subtree."
require_match modules/copyparty/default.nix '\[/\$username/emails\]' \
  "Copyparty must generate each user's mail archive as a read-only subtree."
forbid_match modules/copyparty/default.nix "\\[/''\\$\\{u\\}\\]" \
  "Copyparty must not expose each user's broad top-level root."
forbid_match modules/copyparty/default.nix '\[/shared\]' \
  "Copyparty must not expose the broad shared root."
forbid_match modules/copyparty/default.nix '\[/shared/documents\]' \
  "Copyparty must not expose Paperless archives."
forbid_match modules/copyparty/default.nix '\[/documents\]' \
  "Copyparty must not expose the old global documents mount."
forbid_match modules/copyparty/default.nix '\[/audiobooks\]' \
  "Copyparty must not expose the old global audiobooks mount."
forbid_match modules/copyparty/default.nix '\[/books\]' \
  "Copyparty must not expose the old global books mount."
forbid_match modules/copyparty/default.nix '\[/videos\]' \
  "Copyparty must not expose the old global videos mount."
forbid_match modules/copyparty/default.nix '\[/shared/public\]' \
  "Copyparty must not retain the public subdirectory."
forbid_match modules/copyparty/default.nix '\[/shared/exchange\]' \
  "Copyparty must not retain the exchange subdirectory."
forbid_match modules/copyparty/default.nix '\[/shared/photos\]' \
  "Copyparty must not retain the photos subdirectory."
require_json_equal "$(snapshot_query '.config.hasCopypartyRuntimeConfigSyncService')" 'true' \
  "The host must declare the dedicated Copyparty runtime-config sync service."

require_json_equal "$(snapshot_query '.config.powerGovernor')" '"powersave"' \
  "Power management must retain the powersave governor."
require_json_equal "$(snapshot_query '.config.nightlySuspendTimer')" '"*-*-* 23:30:00"' \
  "Nightly suspend must keep the current schedule."
require_json_equal "$(snapshot_query '.config.mailArchivePort')" '9011' \
  "Mail archive UI must keep the expected local port."
require_json_equal "$(snapshot_query '.config.mailArchiveDataDir')" '"/persist/appdata/mail-archive-ui"' \
  "Mail archive UI state must live on the SSD-backed persist volume."
require_json_equal "$(snapshot_query '.config.mailArchiveAccountStateRoot')" '"/persist/appdata/mail-archive-ui/accounts"' \
  "Mail archive UI derived per-account state must live under the SSD-backed persist volume."
require_json_equal "$(snapshot_query '.config.mailArchivePaperlessConsumeRoot')" '"/mnt/data/paperless/inbox/mail-archive"' \
  "Mail archive UI must point Paperless filing at the dedicated consume subtree."
require_json_equal "$(snapshot_query '.config.mailArchivePaperlessStagingDir')" '"/mnt/data/paperless/.mail-archive-paperless-staging"' \
  "Mail archive UI must stage Paperless handoffs outside the watched consume subtree."
require_fixed modules/mail-archive-paperless/default.nix '-m u:mail-archive-ui:--x' \
  "Mail archive UI must retain traversal access to the Paperless inbox parent directory."
require_fixed rust/apps/mail-archive-ui/Cargo.toml 'landlock = "0.4.4"' \
  "Mail archive UI must depend on the Landlock crate for process self-sandboxing."
require_json_equal "$(snapshot_query '.vars.paperlessEnableDangerousMacroOfficeParsing')" 'false' \
  "Paperless dangerous Office parsing must stay disabled by default."
require_json_equal "$(snapshot_query '.vars.paperlessOcrLanguage')" '"eng"' \
  "Paperless OCR language must remain operator-configurable through vars."
require_json_equal "$(snapshot_query '.config.paperlessDataDir')" '"/var/lib/paperless"' \
  "Paperless state must live under /var/lib."
require_json_equal "$(snapshot_query '.config.paperlessConfigureTika')" 'true' \
  "Paperless must enable Tika-backed Office and email parsing."
require_json_equal "$(snapshot_query '.config.paperlessExporterEnable')" 'true' \
  "Paperless must enable scheduled exports."
require_json_equal "$(snapshot_query '.config.paperlessExporterDirectory')" '"/mnt/data/paperless/export"' \
  "Paperless exports must land in the dedicated Paperless export directory."
require_json_equal "$(snapshot_query '.config.paperlessExporterOnCalendar')" '"02:00"' \
  "Paperless exports must complete before the system-state backup window."
require_json_equal "$(snapshot_query '.config.paperlessOcrLanguage')" "$(snapshot_query '.vars.paperlessOcrLanguage')" \
  "Paperless OCR language must follow vars.paperlessOcrLanguage."
require_json_equal "$(snapshot_query '.config.paperlessOcrClean')" '"clean"' \
  "Paperless must enable OCR cleanup for imported documents."
require_json_equal "$(snapshot_query '.config.paperlessOcrOutputType')" '"pdfa"' \
  "Paperless must archive OCR output as PDF/A."
require_json_equal "$(snapshot_query '.config.paperlessConsumerInotifyDelay')" '"2"' \
  "Paperless must wait briefly for inotify bursts before consuming files."
paperless_ignore_patterns_json="$(snapshot_query '.config.paperlessIgnorePatterns')"
forbid_json_contains "$paperless_ignore_patterns_json" "*.[dD][oO][cC][xX]" \
  "Paperless must allow safe .docx ingestion by default."
forbid_json_contains "$paperless_ignore_patterns_json" "*.[xX][lL][sS][xX]" \
  "Paperless must allow safe .xlsx ingestion by default."
forbid_json_contains "$paperless_ignore_patterns_json" "*.[oO][dD][tT]" \
  "Paperless must allow safe .odt ingestion by default."
forbid_json_contains "$paperless_ignore_patterns_json" "*.[eE][mM][lL]" \
  "Paperless must allow .eml ingestion by default."
require_json_contains "$paperless_ignore_patterns_json" "*.[dD][oO][cC]" \
  "Paperless must block legacy .doc ingestion by default."
require_json_contains "$paperless_ignore_patterns_json" "*.[xX][lL][sS]" \
  "Paperless must block legacy .xls ingestion by default."
require_json_contains "$paperless_ignore_patterns_json" "*.[dD][oO][cC][mM]" \
  "Paperless must block macro-capable .docm ingestion by default."
require_json_contains "$paperless_ignore_patterns_json" "*.[xX][lL][sS][mM]" \
  "Paperless must block macro-capable .xlsm ingestion by default."
require_json_contains "$paperless_ignore_patterns_json" "*.[pP][pP][tT][xX]" \
  "Paperless must block broader presentation ingestion by default."
require_json_contains "$paperless_ignore_patterns_json" "*.[oO][dD][sS]" \
  "Paperless must block broader spreadsheet ingestion by default."
require_json_contains "$paperless_ignore_patterns_json" "*.[oO][dD][pP]" \
  "Paperless must block broader presentation ingestion by default."
danger_paperless_ignore_patterns_json="$(danger_query '.paperlessIgnorePatterns')"
forbid_json_contains "$danger_paperless_ignore_patterns_json" "*.[dD][oO][cC]" \
  "Paperless dangerous mode must re-enable legacy .doc ingestion."
forbid_json_contains "$danger_paperless_ignore_patterns_json" "*.[xX][lL][sS]" \
  "Paperless dangerous mode must re-enable legacy .xls ingestion."
forbid_json_contains "$danger_paperless_ignore_patterns_json" "*.[dD][oO][cC][mM]" \
  "Paperless dangerous mode must re-enable macro-capable .docm ingestion."
forbid_json_contains "$danger_paperless_ignore_patterns_json" "*.[xX][lL][sS][mM]" \
  "Paperless dangerous mode must re-enable macro-capable .xlsm ingestion."
forbid_json_contains "$danger_paperless_ignore_patterns_json" "*.[pP][pP][tT][xX]" \
  "Paperless dangerous mode must re-enable broader presentation ingestion."
forbid_json_contains "$danger_paperless_ignore_patterns_json" "*.[oO][dD][sS]" \
  "Paperless dangerous mode must re-enable broader spreadsheet ingestion."
forbid_json_contains "$danger_paperless_ignore_patterns_json" "*.[oO][dD][pP]" \
  "Paperless dangerous mode must re-enable broader presentation ingestion."
require_json_equal "$(snapshot_query '.config.paperlessConsumerRecursive')" '"true"' \
  "Paperless must recurse into the mail archive consume subtree."
require_json_equal "$(snapshot_query '.config.paperlessConsumerSubdirsAsTags')" '"true"' \
  "Paperless must tag imported mail attachments from consume subdirectories."
require_json_equal "$(snapshot_query '.config.paperlessSocialAccountDefaultGroups')" '"Users"' \
  "Paperless social signup must attach first-login users to the local Users group."
require_json_equal "$(snapshot_query '.config.hasLegacyPaperlessSocialDefaultGroups')" 'false' \
  "Paperless must not expose the legacy typoed social default-groups setting."
require_json_contains "$(snapshot_query '.config.paperlessOidcEnvScript')" 'oauth_pkce_enabled' \
  "Paperless OIDC provider generation must explicitly enable PKCE."

require_json_equal "$(snapshot_query '.config.kavitaDataDir')" '"/var/lib/kavita"' \
  "Kavita state must live under /var/lib."
require_json_equal "$(snapshot_query '.config.kavitaDisablePasswordAuthentication')" 'true' \
  "Kavita must disable non-admin local password authentication when OIDC is enabled."
require_json_equal "$(snapshot_query '.config.jellyfinDataDir')" '"/var/lib/jellyfin"' \
  "Jellyfin state must live under /var/lib."
require_json_equal "$(snapshot_query '.config.audiobookshelfExtraGroups')" '["audiobookshelf-media"]' \
  "Audiobookshelf must use the app-specific media group."
require_json_equal "$(snapshot_query '.config.kavitaExtraGroups')" '["kavita-media"]' \
  "Kavita must use the app-specific media group."
require_json_equal "$(snapshot_query '.config.jellyfinExtraGroups')" '["jellyfin-media"]' \
  "Jellyfin must use the app-specific media group."
forbid_match modules/audiobookshelf/service.nix 'media-library' \
  "Audiobookshelf must not retain the removed broad media-library group."
require_fixed modules/audiobookshelf/oidc-bootstrap.nix '["audiobookshelf://oauth", "lissen://oauth"]' \
  "Audiobookshelf must allow both the official app and Lissen mobile redirect URIs."
forbid_match modules/audiobookshelf/oidc-bootstrap.nix 'audiobookshelf-oidc-bootstrap-v1\.done|marker_file=' \
  "Audiobookshelf OIDC bootstrap must keep converging instead of persisting a done-marker gate."
require_fixed modules/kavita/default.nix 'DisablePasswordAuthentication = true;' \
  "Kavita declarative settings must disable non-admin local password authentication."
forbid_match modules/kavita/default.nix 'media-library' \
  "Kavita must not retain the removed broad media-library group."
forbid_match modules/Core_Modules/kanidm/provision.nix 'allowInsecureClientDisablePkce = true;' \
  "Kanidm must not keep the Paperless PKCE disable override."
forbid_match modules/jellyfin/service.nix 'media-library' \
  "Jellyfin must not retain the removed broad media-library group."
require_json_equal "$(snapshot_query '.config.hasAudiobookshelfTimer')" 'false' \
  "Audiobookshelf must not retain the retired library sync timer."
require_json_equal "$(snapshot_query '.config.hasKavitaTimer')" 'false' \
  "Kavita must not retain the retired library sync timer."
require_json_equal "$(snapshot_query '.config.hasJellyfinTimer')" 'false' \
  "Jellyfin must not retain the retired reconcile timer."
require_json_equal "$(printf '%s\n' "$(snapshot_query '.config.kanidmProvisionGroups')" | jq -c 'has("jellyfin-users")')" 'false' \
  "Kanidm must not provision a Jellyfin login group."
require_json_equal "$(printf '%s\n' "$(snapshot_query '.config.kanidmProvisionGroups')" | jq -c 'has("jellyfin-admin")')" 'false' \
  "Kanidm must not provision a Jellyfin admin-intent group."
require_json_equal "$(printf '%s\n' "$(snapshot_query '.config.kanidmProvisionGroups')" | jq -c 'has("fileshare_users")')" 'false' \
  "Kanidm must retire the old fileshare_users group."
require_json_equal "$(printf '%s\n' "$(snapshot_query '.config.kanidmProvisionGroups')" | jq -c 'has("user-files")')" 'true' \
  "Kanidm must provision the personal file-access group."
require_json_equal "$(printf '%s\n' "$(snapshot_query '.config.kanidmProvisionGroups')" | jq -c 'has("shared-files-ro")')" 'true' \
  "Kanidm must provision the shared read-only group."
require_json_equal "$(printf '%s\n' "$(snapshot_query '.config.kanidmProvisionGroups')" | jq -c 'has("shared-files-rw")')" 'true' \
  "Kanidm must provision the shared read-write group."
require_json_equal "$(snapshot_query '.config.hasKanidmFilesPosixGroupsService')" 'true' \
  "The host must declare the Kanidm POSIX-group convergence service."
require_json_equal "$(snapshot_query '.config.hasSharedFilesAccessSyncService')" 'true' \
  "The host must declare the shared-root ACL convergence service."
require_json_equal "$(snapshot_query '.config.kanidmInstanceUrl')" "\"https://$(snapshot_query '.vars.kanidmDomain' | jq -r .):8443\"" \
  "Kanidm provisioning must use the real hostname on the loopback-bound Kanidm port."
require_json_equal "$(snapshot_query '.vars.fileAccessPosixGids["user-files"]')" '2001' \
  "The personal file-access group must use the fixed user-files POSIX GID."
require_json_equal "$(snapshot_query '.vars.fileAccessPosixGids["shared-files-ro"]')" '2002' \
  "The shared read-only group must use the fixed POSIX GID."
require_json_equal "$(snapshot_query '.vars.fileAccessPosixGids["shared-files-rw"]')" '2003' \
  "The shared read-write group must use the fixed POSIX GID."
require_json_contains "$(snapshot_query '.config.kanidmFilesPosixGroupsScript')" 'kanidm group posix set' \
  "The POSIX-group convergence service must assign fixed GIDs through the Kanidm CLI."
require_json_contains "$(snapshot_query '.config.kanidmFilesPosixGroupsScript')" '--gidnumber' \
  "The POSIX-group convergence service must pass explicit gidnumber values."
require_json_contains "$(snapshot_query '.config.kanidmFilesPosixGroupsScript')" 'kanidmAdminPass' \
  "The POSIX-group convergence service must use the IDM admin secret."
require_json_contains "$(snapshot_query '.config.kanidmFilesPosixGroupsScript')" '-D idm_admin' \
  "The POSIX-group convergence service must authenticate as idm_admin."
require_match modules/samba/default.nix 'collect_group_members' \
  "Personal fileshare roots must be provisioned from explicit Kanidm group membership."
require_match modules/samba/default.nix 'collect_group_members \$\{lib\.escapeShellArg userFilesGroup\}' \
  "Personal fileshare roots must be provisioned only from the user-files group."
require_match modules/samba/default.nix 'g:\$\{sharedFilesReadOnlyGroup\}:r-x' \
  "The shared-root ACL sync must grant read-only traversal to the shared read-only group."
require_match modules/samba/default.nix 'g:\$\{sharedFilesReadWriteGroup\}:rwx' \
  "The shared-root ACL sync must allow top-level shared uploads for the shared read-write group."
require_match modules/samba/default.nix 'g:\$\{sharedFilesReadWriteGroup\}:r--' \
  "The shared-root ACL sync must make descendant files peer-read-only for the shared read-write group."
require_json_contains "$(snapshot_query '.config.kanidmPamAllowedLoginGroups')" "user-files" \
  "Kanidm PAM access must allow the personal file-access group."
require_json_contains "$(snapshot_query '.config.kanidmPamAllowedLoginGroups')" "shared-files-ro" \
  "Kanidm PAM access must allow the shared read-only group."
require_json_contains "$(snapshot_query '.config.kanidmPamAllowedLoginGroups')" "shared-files-rw" \
  "Kanidm PAM access must allow the shared read-write group."
require_json_equal "$(snapshot_query '.config.oauth2ProxyScope')" '"openid profile email groups"' \
  "The files OAuth2 Proxy must request group claims from Kanidm."
require_json_contains "$(snapshot_query '.config.oauth2ProxyAllowedGroups')" "user-files" \
  "The files OAuth2 Proxy must allow the personal file-access group."
require_json_contains "$(snapshot_query '.config.oauth2ProxyAllowedGroups')" "shared-files-ro" \
  "The files OAuth2 Proxy must allow the shared read-only group."
require_json_contains "$(snapshot_query '.config.oauth2ProxyAllowedGroups')" "shared-files-rw" \
  "The files OAuth2 Proxy must allow the shared read-write group."
forbid_match modules 'acceptInvalidCerts = true;|--accept-invalid-certs' \
  "Repo-managed Kanidm automation must not bypass TLS validation."
require_json_equal "$(snapshot_query '.config.audiobookshelfWorkingDirectory')" '"/var/lib/audiobookshelf"' \
  "Audiobookshelf state must live under /var/lib."
require_json_equal "$(snapshot_query '.config.hasAudiobookshelfService')" 'false' \
  "Audiobookshelf must not retain the retired library sync service."
require_json_equal "$(snapshot_query '.config.hasKavitaService')" 'false' \
  "Kavita must not retain the retired library sync service."
require_json_equal "$(snapshot_query '.config.hasJellyfinService')" 'false' \
  "Jellyfin must not retain the retired reconcile service."
require_json_equal "$(snapshot_query '.config.hasAppStateMigrationService')" 'false' \
  "The system must not retain the retired app-state migration service."
require_json_equal "$(snapshot_query '.config.mailArchiveSyncConditionMount')" '"/mnt/data"' \
  "Mail archive sync must be gated on the data pool mount."
require_json_equal "$(snapshot_query '.config.mailArchiveUiUmask')" '"0077"' \
  "Mail archive UI must set a restrictive UMask."
require_json_contains "$(snapshot_query '.config.mailArchiveUiReadWritePaths')" "/mnt/data/paperless/inbox/mail-archive" \
  "Mail archive UI must only gain write access to the dedicated Paperless consume subtree."
require_json_contains "$(snapshot_query '.config.mailArchiveUiReadWritePaths')" "/mnt/data/paperless/.mail-archive-paperless-staging" \
  "Mail archive UI must write Paperless staging output to the dedicated staging directory."
require_json_contains "$(snapshot_query '.config.mailArchiveUiReadWritePaths')" "/persist/appdata/mail-archive-ui/accounts" \
  "Mail archive UI must gain write access to the SSD-backed per-account derived state root."
require_json_equal "$(snapshot_query '.config.mailArchiveSyncUmask')" '"0077"' \
  "Mail archive sync must set a restrictive UMask."
mail_archive_ui_path_json="$(snapshot_query '.config.mailArchiveUiPath')"
if ! printf '%s\n' "$mail_archive_ui_path_json" | rg 'ripmime-[^"]*' >/dev/null; then
  echo "❌ Mail archive UI must include ripmime in its runtime path."
  exit 1
fi
if ! printf '%s\n' "$mail_archive_ui_path_json" | rg -F 'file-' >/dev/null; then
  echo "❌ Mail archive UI must include file in its runtime path."
  exit 1
fi
require_json_equal "$(snapshot_query '.config.mailArchiveSyncTimer')" '"*-*-* 06,18:15:00"' \
  "Mail archive sync must keep the current schedule."
require_fixed modules/Core_Modules/storage/layout.nix 'vars.paperlessMailArchiveConsumeRoot' \
  "Storage layout must provision the dedicated Paperless consume subtree for mail attachments."
require_fixed modules/Core_Modules/storage/layout.nix 'vars.paperlessMailArchiveStagingRoot' \
  "Storage layout must provision the dedicated Paperless staging directory."
require_match rust/apps/mail-archive-ui/src/main.rs '\.route\("/accounts/\{id\}/edit"' \
  "Mail archive UI must expose the mailbox edit route."
require_match rust/apps/mail-archive-ui/src/main.rs '\.route\("/accounts/\{id\}/toggle-sync"' \
  "Mail archive UI must expose the mailbox schedule toggle route."
require_match rust/apps/mail-archive-ui/src/main.rs '\.route\("/accounts/\{id\}/reindex"' \
  "Mail archive UI must expose the mailbox reindex route."
require_fixed modules/Core_Modules/kanidm/account-policy.nix 'kanidm group account-policy auth-expiry' \
  "Kanidm must declaratively apply the account policy auth session expiry."
require_fixed modules/Core_Modules/kanidm/account-policy.nix 'idm_all_persons' \
  "Kanidm auth session grace must target the default people policy."

echo "✅ App core config tests passed."
