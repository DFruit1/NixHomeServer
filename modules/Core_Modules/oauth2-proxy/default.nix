{ lib, pkgs, vars }:

let
  defaultScope = "openid profile email groups_name";
  loopCount = 60;
  loopback = vars.networking.loopbackIPv4;

  commonExtraConfig = {
    "oidc-groups-claim" = "groups";
    "pass-user-headers" = true;
    "provider-ca-file" = "/etc/ssl/certs/ca-bundle.crt";
    "skip-provider-button" = true;
  };

  commonProxyArgs =
    { clientId
    , domain
    , port
    , upstream
    , scope ? defaultScope
    , codeChallengeMethod ? "S256"
    , redirectPath ? "/oauth2/callback"
    , issuerUrl ? vars.kanidmIssuer clientId
    ,
    }:
    [
      "--provider=oidc"
      "--approval-prompt=auto"
      "--scope=${scope}"
      "--email-domain=*"
      "--upstream=${upstream}"
      "--redirect-url=https://${domain}${redirectPath}"
      "--http-address=${loopback}:${toString port}"
      "--client-id=${clientId}"
      "--oidc-issuer-url=${issuerUrl}"
      "--reverse-proxy=true"
      "--set-xauthrequest=true"
      "--pass-user-headers=true"
      "--oidc-groups-claim=groups"
      "--provider-ca-file=/etc/ssl/certs/ca-bundle.crt"
      "--skip-provider-button=true"
      "--code-challenge-method=${codeChallengeMethod}"
    ];

  mkDiscoveryWaitScript =
    { serviceName
    , clientId
    ,
    }:
    pkgs.writeShellScript "${serviceName}-wait-for-discovery" ''
      set -euo pipefail

      discovery_url=${lib.escapeShellArg (vars.kanidmDiscoveryUrl clientId)}

      for _ in $(${pkgs.coreutils}/bin/seq 1 ${toString loopCount}); do
        if ${pkgs.curl}/bin/curl --silent --show-error --fail --cacert /etc/ssl/certs/ca-bundle.crt "$discovery_url" >/dev/null; then
          exit 0
        fi
        ${pkgs.coreutils}/bin/sleep 1
      done

      echo "Timed out waiting for Kanidm OIDC discovery at $discovery_url" >&2
      exit 1
    '';

  mkUpstreamWaitScript =
    { serviceName
    , displayName
    , url
    , okStatusCodes ? [ "200" ]
    ,
    }:
    let
      okPattern = lib.concatStringsSep "|" okStatusCodes;
    in
    pkgs.writeShellScript "${serviceName}-wait-for-upstream" ''
      set -euo pipefail

      upstream_url=${lib.escapeShellArg url}

      for _ in $(${pkgs.coreutils}/bin/seq 1 ${toString loopCount}); do
        status_code="$(${pkgs.curl}/bin/curl \
          --silent \
          --show-error \
          --output /dev/null \
          --write-out '%{http_code}' \
          "$upstream_url" || true)"

        case "$status_code" in
          ${okPattern}) exit 0 ;;
        esac

        ${pkgs.coreutils}/bin/sleep 1
      done

      echo "Timed out waiting for ${displayName} upstream at $upstream_url" >&2
      exit 1
    '';

  mkProxyArgs =
    { clientId
    , clientSecretFile
    , cookieSecretFile
    , cookieName
    , domain
    , port
    , upstream
    , allowedGroups ? [ ]
    , scope ? defaultScope
    , codeChallengeMethod ? "S256"
    , redirectPath ? "/oauth2/callback"
    , issuerUrl ? vars.kanidmIssuer clientId
    , extraArgs ? [ ]
    ,
    }:
    commonProxyArgs
      {
        inherit clientId domain port upstream scope redirectPath issuerUrl;
        inherit codeChallengeMethod;
      }
    ++ [
      "--client-secret-file=${clientSecretFile}"
      "--cookie-secret-file=${cookieSecretFile}"
      "--cookie-name=${cookieName}"
    ]
    ++ map (group: "--allowed-group=${group}") allowedGroups
    ++ extraArgs;
in
{
  mkNixosService =
    { clientId
    , domain
    , port
    , upstream
    , allowedGroups ? [ ]
    , scope ? defaultScope
    , codeChallengeMethod ? "S256"
    , redirectPath ? "/oauth2/callback"
    , extraConfig ? { }
    ,
    }:
    {
      enable = true;
      provider = "oidc";
      approvalPrompt = "auto";
      oidcIssuerUrl = vars.kanidmIssuer clientId;
      inherit scope;
      email.domains = [ "*" ];
      upstream = lib.toList upstream;
      redirectURL = "https://${domain}${redirectPath}";
      httpAddress = "${loopback}:${toString port}";
      clientID = clientId;
      reverseProxy = true;
      setXauthrequest = true;
      extraConfig =
        commonExtraConfig
        // { "code-challenge-method" = codeChallengeMethod; }
        // lib.optionalAttrs (allowedGroups != [ ]) {
          "allowed-group" = allowedGroups;
        }
        // extraConfig;
    };

  mkSidecarService =
    { serviceName
    , description
    , clientId
    , clientSecretFile
    , cookieSecretFile
    , cookieName
    , domain
    , port
    , upstream
    , allowedGroups ? [ ]
    , scope ? defaultScope
    , codeChallengeMethod ? "S256"
    , redirectPath ? "/oauth2/callback"
    , serviceDependencies ? [ ]
    , upstreamCheck ? null
    , restartSec ? null
    , extraProxyArgs ? [ ]
    , extraReadOnlyPaths ? [ ]
    ,
    }:
    let
      proxyArgs = mkProxyArgs {
        inherit
          clientId
          clientSecretFile
          cookieSecretFile
          cookieName
          domain
          port
          upstream
          allowedGroups
          scope
          codeChallengeMethod
          redirectPath
          ;
        extraArgs = extraProxyArgs;
      };
      waitForDiscoveryScript = mkDiscoveryWaitScript {
        inherit serviceName clientId;
      };
      waitForUpstreamScript =
        if upstreamCheck == null then
          null
        else
          mkUpstreamWaitScript {
            inherit serviceName;
            displayName = upstreamCheck.displayName;
            url = upstreamCheck.url;
            okStatusCodes = upstreamCheck.okStatusCodes or [ "200" ];
          };
      execStartPre =
        [ waitForDiscoveryScript ]
        ++ lib.optional (waitForUpstreamScript != null) waitForUpstreamScript;
    in
    {
      systemd.services.${serviceName} = {
        inherit description;
        wantedBy = [ "multi-user.target" ];
        wants = [
          "network-online.target"
          "unbound.service"
          "kanidm.service"
        ] ++ serviceDependencies;
        after = [
          "network-online.target"
          "unbound.service"
          "kanidm.service"
        ] ++ serviceDependencies;

        serviceConfig =
          {
            Type = "simple";
            User = "oauth2-proxy";
            Group = "oauth2-proxy";
            ExecStartPre = execStartPre;
            ExecStart = "${pkgs.oauth2-proxy}/bin/oauth2-proxy ${lib.concatStringsSep " " (map lib.escapeShellArg proxyArgs)}";
            Restart = "on-failure";
            RestartSec = "10s";
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
            ];
            ReadOnlyPaths = [
              clientSecretFile
              cookieSecretFile
            ] ++ extraReadOnlyPaths;
          }
          // lib.optionalAttrs (restartSec != null) {
            RestartSec = restartSec;
          };
      };
    };
}
