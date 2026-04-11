{ lib, config, pkgs, vars, ... }:

{
  services.audiobookshelf = {
    enable = true;
    dataDir = "${vars.dataRoot}/audiobookshelf";
    port = vars.audiobookshelfPort;
  };

  ## Ensure runtime directory exists and is the service cwd
  systemd.services.audiobookshelf.serviceConfig = {
    WorkingDirectory = lib.mkForce "${vars.dataRoot}/audiobookshelf";
  };

  systemd.services.audiobookshelf-oidc-bootstrap = {
    description = "Synchronize Audiobookshelf OIDC settings";
    wantedBy = [ "multi-user.target" ];
    after = [
      "audiobookshelf.service"
      "caddy.service"
      "kanidm.service"
    ];
    wants = [
      "audiobookshelf.service"
      "caddy.service"
      "kanidm.service"
    ];
    path = with pkgs; [
      curl
      jq
      sqlite
    ];
    script = ''
      set -euo pipefail

      db="${vars.dataRoot}/audiobookshelf/config/absdatabase.sqlite"
      for _ in $(seq 1 30); do
        [[ -f "$db" ]] && break
        sleep 1
      done
      [[ -f "$db" ]] || {
        echo "Audiobookshelf database not found at $db" >&2
        exit 1
      }

      discovery="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
        --resolve '${vars.kanidmDomain}:443:127.0.0.1' \
        '${vars.kanidmDiscoveryUrl "abs-web"}')"
      client_secret="$(< ${config.age.secrets.absClientSecret.path})"
      current="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
        "select value from settings where key = 'server-settings';")"
      [[ -n "$current" ]] || {
        echo "Audiobookshelf server-settings row is missing" >&2
        exit 1
      }

      updated="$(printf '%s' "$current" | ${pkgs.jq}/bin/jq -c \
        --arg clientId "abs-web" \
        --arg clientSecret "$client_secret" \
        --arg buttonText "Login with Kanidm" \
        --arg subfolder "/audiobookshelf" \
        --argjson discovery "$discovery" \
        '
          .authActiveAuthMethods = (((.authActiveAuthMethods // []) + ["openid"]) | unique)
          | .authOpenIDIssuerURL = $discovery.issuer
          | .authOpenIDAuthorizationURL = $discovery.authorization_endpoint
          | .authOpenIDTokenURL = $discovery.token_endpoint
          | .authOpenIDUserInfoURL = $discovery.userinfo_endpoint
          | .authOpenIDJwksURL = $discovery.jwks_uri
          | .authOpenIDLogoutURL = ($discovery.end_session_endpoint // null)
          | .authOpenIDClientID = $clientId
          | .authOpenIDClientSecret = $clientSecret
          | .authOpenIDTokenSigningAlgorithm = (($discovery.id_token_signing_alg_values_supported // ["ES256"]) | .[0])
          | .authOpenIDButtonText = $buttonText
          | .authOpenIDAutoLaunch = false
          | .authOpenIDAutoRegister = true
          | .authOpenIDMatchExistingBy = "username"
          | .authOpenIDMobileRedirectURIs = ["audiobookshelf://oauth"]
          | .authOpenIDGroupClaim = ""
          | .authOpenIDAdvancedPermsClaim = ""
          | .authOpenIDSubfolderForRedirectURLs = $subfolder
        ')"

      if [[ "$current" == "$updated" ]]; then
        exit 0
      fi

      escaped="$(printf '%s' "$updated" | ${pkgs.perl}/bin/perl -pe 's/\x27/\x27\x27/g')"
      ${pkgs.sqlite}/bin/sqlite3 "$db" \
        "update settings set value = '$escaped' where key = 'server-settings';"
      /run/current-system/sw/bin/systemctl restart audiobookshelf.service
    '';
  };

  systemd.tmpfiles.rules = [
    "d ${vars.dataRoot}/audiobookshelf 0755 audiobookshelf audiobookshelf -"
  ];
}
