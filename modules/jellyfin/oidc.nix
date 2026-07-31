{ config, lib, pkgs, vars, jellyfinOidcPlugin, ... }:

let
  pluginGuid = "d4e5f6a7-b8c9-0d1e-2f3a-4b5c6d7e8f90";
  pluginVersion = "1.0.8.0";
  dataDir = "/var/lib/jellyfin";
  pluginMountDir = "${dataDir}/plugins/OIDC RBAC_${pluginVersion}";
  pluginSourceDir = "${jellyfinOidcPlugin}/lib/jellyfin-plugin-oidc";
  pluginConfigFile = "${dataDir}/plugins/configurations/Jellyfin.Plugin.OIDC.xml";
  apiKeyFile = "${dataDir}/data/library-sync.api-key";
  jellyfinUrl = "http://${vars.networking.loopbackIPv4}:${toString vars.networking.ports.jellyfin}";
  publicBaseUrl = "https://videos.${vars.domain}";
  authority = vars.kanidmIssuer "jellyfin-web";
  pluginAssemblies = [
    "IdentityModel.dll"
    "Jellyfin.Plugin.OIDC.dll"
    "Microsoft.IdentityModel.Abstractions.dll"
    "Microsoft.IdentityModel.JsonWebTokens.dll"
    "Microsoft.IdentityModel.Logging.dll"
    "Microsoft.IdentityModel.Protocols.OpenIdConnect.dll"
    "Microsoft.IdentityModel.Protocols.dll"
    "Microsoft.IdentityModel.Tokens.dll"
    "System.IdentityModel.Tokens.Jwt.dll"
  ];
  pluginManifestInstaller = pkgs.writeShellApplication {
    name = "jellyfin-oidc-manifest-install";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      set -euo pipefail
      install -m 0644 \
        ${lib.escapeShellArg "${pluginSourceDir}/meta.json"} \
        ${lib.escapeShellArg "${pluginMountDir}/meta.json"}
      ${lib.concatMapStringsSep "\n" (assembly: ''
        install -m 0444 \
          ${lib.escapeShellArg "${pluginSourceDir}/${assembly}"} \
          ${lib.escapeShellArg "${pluginMountDir}/${assembly}"}
      '') pluginAssemblies}
    '';
  };
in
{
  config = {
    systemd.tmpfiles.settings.jellyfinOidcDirs = {
      "${dataDir}/plugins".d = {
        mode = "0700";
        user = "jellyfin";
        group = "jellyfin";
      };
      "${dataDir}/plugins/configurations".d = {
        mode = "0700";
        user = "jellyfin";
        group = "jellyfin";
      };
      "${pluginMountDir}".d = {
        mode = "0750";
        user = "jellyfin";
        group = "jellyfin";
      };
    };

    systemd.services.jellyfin = {
      restartTriggers = [ jellyfinOidcPlugin ];
      serviceConfig = {
        # Keep local copies so a rollback to a generation without this module
        # cannot leave Jellyfin pointing into a vanished /run bind mount.
        ExecStartPre = lib.mkAfter [
          "${pluginManifestInstaller}/bin/jellyfin-oidc-manifest-install"
        ];
      };
    };

    systemd.services.jellyfin-oidc-bootstrap-v1 = {
      description = "Reconcile Jellyfin OIDC, Quick Connect, and web-login branding";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "jellyfin.service"
        "jellyfin-library-bootstrap-v1.service"
        "kanidm.service"
        "caddy.service"
      ];
      after = [
        "jellyfin.service"
        "jellyfin-library-bootstrap-v1.service"
        "kanidm.service"
        "caddy.service"
      ];
      path = with pkgs; [
        coreutils
        curl
        diffutils
        gnugrep
        jq
      ];
      script = ''
        set -euo pipefail

        api_key_file=${lib.escapeShellArg apiKeyFile}
        plugin_config_file=${lib.escapeShellArg pluginConfigFile}
        api_url=${lib.escapeShellArg jellyfinUrl}
        plugin_config_url="$api_url/Plugins/${pluginGuid}/Configuration"
        system_config_url="$api_url/System/Configuration"
        branding_config_url="$api_url/Branding/Configuration"
        branding_update_url="$api_url/System/Configuration/Branding"
        credential_file="$CREDENTIALS_DIRECTORY/jellyfin-oidc-client-secret"

        [[ -s "$credential_file" ]] || {
          echo "Jellyfin OIDC client-secret credential is unavailable." >&2
          exit 1
        }
        [[ -s "$api_key_file" ]] || {
          echo "Jellyfin bootstrap API key is unavailable; retrying reconciliation." >&2
          exit 1
        }

        client_secret="$(tr -d '\r\n' <"$credential_file")"
        api_key="$(tr -d '\r\n' <"$api_key_file")"
        [[ -n "$client_secret" && -n "$api_key" ]] || {
          echo "Jellyfin OIDC credential or bootstrap API key is empty." >&2
          exit 1
        }

        api_get() {
          curl --fail --silent --show-error \
            --header "X-Emby-Token: $api_key" \
            "$1"
        }

        api_post() {
          local url="$1"
          local body_file="$2"
          curl --fail --silent --show-error \
            --request POST \
            --header "X-Emby-Token: $api_key" \
            --header "Content-Type: application/json" \
            --data-binary "@$body_file" \
            "$url" >/dev/null
        }

        ready=0
        for _ in $(seq 1 60); do
          if api_get "$plugin_config_url" >/dev/null 2>&1; then
            ready=1
            break
          fi
          sleep 2
        done
        (( ready == 1 )) || {
          echo "Jellyfin or the pinned OIDC plugin did not become ready in time." >&2
          exit 1
        }

        work_dir="$(mktemp -d)"
        trap 'rm -rf "$work_dir"' EXIT
        current_plugin="$work_dir/current-plugin.json"
        desired_plugin="$work_dir/desired-plugin.json"

        api_get "$plugin_config_url" >"$current_plugin"
        jq -cn \
          --arg clientSecret "$client_secret" \
          --arg authority ${lib.escapeShellArg authority} \
          --arg serverBaseUrl ${lib.escapeShellArg publicBaseUrl} \
          '{
            "Providers": [{
              "ProviderId": "kanidm",
              "DisplayName": "Kanidm",
              "Authority": $authority,
              "ClientId": "jellyfin-web",
              "ClientSecret": $clientSecret,
              "Scopes": "openid profile email",
              "RoleClaim": "groups",
              "UsernameClaim": "preferred_username",
              "DisplayNameClaim": "name",
              "PictureClaim": "picture",
              "SyncProfileImage": false,
              "Enabled": true,
              "ButtonColor": "#4285F4",
              "ButtonIcon": "",
              "AdditionalParameters": "",
              "ServerBaseUrl": $serverBaseUrl
            }],
            "RoleMappings": [],
            "DefaultProvider": "kanidm",
            "AutoCreateUsers": false,
            "DefaultRoleName": ""
          }' >"$desired_plugin"

        current_public="$(jq -S 'del(.Providers[]?.ClientSecret)' "$current_plugin")"
        desired_public="$(jq -S 'del(.Providers[]?.ClientSecret)' "$desired_plugin")"
        current_secret="$(jq -r '.Providers[]? | select(.ProviderId == "kanidm") | .ClientSecret // empty' "$current_plugin")"
        if [[ "$current_public" != "$desired_public" || "$current_secret" != "$client_secret" ]]; then
          api_post "$plugin_config_url" "$desired_plugin"
          echo "Jellyfin OIDC provider configuration reconciled."
        else
          echo "Jellyfin OIDC provider configuration already converged."
        fi

        for _ in $(seq 1 30); do
          [[ -s "$plugin_config_file" ]] && break
          sleep 1
        done
        [[ -s "$plugin_config_file" ]] || {
          echo "Jellyfin OIDC configuration file was not materialized." >&2
          exit 1
        }
        cp "$plugin_config_file" "$work_dir/plugin-config.xml"
        install -m 0600 -o jellyfin -g jellyfin \
          "$work_dir/plugin-config.xml" "$plugin_config_file"

        current_system="$work_dir/current-system.json"
        desired_system="$work_dir/desired-system.json"
        api_get "$system_config_url" >"$current_system"
        jq '.QuickConnectAvailable = true' "$current_system" >"$desired_system"
        if ! cmp -s "$current_system" "$desired_system"; then
          api_post "$system_config_url" "$desired_system"
          echo "Jellyfin Quick Connect enabled."
        else
          echo "Jellyfin Quick Connect already enabled."
        fi

        login_fragment='<!-- nixhomeserver:jellyfin-oidc:start -->
        <script src="/sso/OIDC/LoginButtons"></script>
        <!-- nixhomeserver:jellyfin-oidc:end -->'
        css_fragment='/* nixhomeserver:jellyfin-oidc:start */
        html.nixhomeserver-oidc-ready form.manualLoginForm,
        html.nixhomeserver-oidc-ready button.btnForgotPassword {
          display: none !important;
        }
        /* nixhomeserver:jellyfin-oidc:end */'

        branding_current="$work_dir/current-branding.json"
        branding_desired="$work_dir/desired-branding.json"
        api_get "$branding_config_url" >"$branding_current"
        if ! jq \
          --arg loginFragment "$login_fragment" \
          --arg cssFragment "$css_fragment" '
          def count($text; $marker):
            if $text == "" then 0
            else (($text | split($marker) | length) - 1)
            end;
          def upsert($text; $start; $end; $fragment):
            (count($text; $start)) as $starts
            | (count($text; $end)) as $ends
            | if $starts == 0 and $ends == 0 then
                if $text == "" then $fragment else $text + "\n" + $fragment end
              elif $starts == 1 and $ends == 1 then
                ($text | index($start)) as $startAt
                | ($text | index($end)) as $endAt
                | if $startAt < $endAt then
                    $text[0:$startAt] + $fragment
                    + $text[($endAt + ($end | length)):]
                  else error("Jellyfin OIDC branding markers are out of order")
                  end
              else error("Jellyfin OIDC branding markers are malformed or partially paired")
              end;
          .LoginDisclaimer = upsert(
            (.LoginDisclaimer // "");
            "<!-- nixhomeserver:jellyfin-oidc:start -->";
            "<!-- nixhomeserver:jellyfin-oidc:end -->";
            $loginFragment
          )
          | .CustomCss = upsert(
            (.CustomCss // "");
            "/* nixhomeserver:jellyfin-oidc:start */";
            "/* nixhomeserver:jellyfin-oidc:end */";
            $cssFragment
          )
        ' "$branding_current" >"$branding_desired"; then
          echo "Refusing to overwrite malformed Jellyfin OIDC branding markers." >&2
          exit 1
        fi

        if ! cmp -s "$branding_current" "$branding_desired"; then
          api_post "$branding_update_url" "$branding_desired"
          echo "Jellyfin OIDC login branding reconciled."
        else
          echo "Jellyfin OIDC login branding already converged."
        fi

        providers="$work_dir/providers.json"
        api_get "$api_url/sso/OIDC/Providers" >"$providers"
        jq -e 'any(.[]; (.ProviderId // .providerId) == "kanidm")' "$providers" >/dev/null || {
          echo "Jellyfin OIDC provider route is not serving the Kanidm provider." >&2
          exit 1
        }
      '';
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "5s";
        UMask = "0077";
        LoadCredential = [
          "jellyfin-oidc-client-secret:${config.age.secrets.jellyfinOidcClientSecret.path}"
        ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "${dataDir}/plugins/configurations" ];
      };
      unitConfig = lib.mkMerge [
        { RequiresMountsFor = [ vars.dataRoot ]; }
        (lib.mkIf vars.dataRootIsMountPoint {
          ConditionPathIsMountPoint = vars.dataRoot;
        })
      ];
    };
  };
}
