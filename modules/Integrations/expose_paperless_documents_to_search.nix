{ config, lib, options, pkgs, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  paperlessPort = vars.networking.ports.paperless;
  tokenFile = "/run/paperless-search-api-token";
in
{
  config = lib.optionalAttrs
    (
      lib.hasAttrByPath [ "repo" "search" ] options
      && lib.hasAttrByPath [ "repo" "paperless" ] options
    )
    (lib.mkIf (config.repo.search.enable && config.services.paperless.enable) {
      # Paperless is runtime-federated: Search queries Paperless's own Tantivy
      # index at request time and never copies document bodies into the index.
      repo.search.sources.paperless = {
        displayName = "Documents";
        sourceType = "paperless-api";
        appBase = "https://paperless.${vars.domain}";
        settings = {
          # Loopback so no TLS/DNS round trip is needed for each query.
          baseUrl = "http://${loopback}:${toString paperlessPort}";
        };
      };

      # Paperless rejects requests whose Host header is not in ALLOWED_HOSTS,
      # so allow its loopback listener for the internal Search client.
      repo.paperless.additionalAllowedHosts = [ loopback ];

      systemd.services.search-ui = {
        environment.SEARCH_PAPERLESS_TOKEN_FILE = tokenFile;
        wants = [ "paperless-search-api-token.service" ];
        after = [ "paperless-search-api-token.service" ];
      };

      # Mints an idempotent DRF token for a dedicated, view-only service user
      # and leaves it where the Search UI reads it. The token itself lives in
      # the Paperless database; only its derived copy is written to /run, so it
      # is never backed up and is regenerated on every boot.
      systemd.services.paperless-search-api-token = {
        description = "Mint the Paperless API token consumed by Search";
        wantedBy = [ "multi-user.target" ];
        wants = [
          "paperless-web.service"
          "paperless-permissions-bootstrap.service"
        ];
        after = [
          "paperless-web.service"
          "paperless-permissions-bootstrap.service"
        ];
        path = [
          config.services.paperless.manage
          pkgs.coreutils
          pkgs.util-linux
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = "10s";
        };
        script = ''
          set -euo pipefail

          db=/var/lib/paperless/db.sqlite3
          for _ in $(seq 1 60); do
            [[ -f "$db" ]] && break
            sleep 1
          done
          [[ -f "$db" ]] || {
            echo "Paperless database not found at $db" >&2
            exit 1
          }

          tmp="$(mktemp /run/paperless-search-api-token.XXXXXX)"
          trap 'rm -f -- "$tmp"' EXIT
          chown paperless:paperless "$tmp"
          chmod 0600 "$tmp"

          runuser -u paperless -- env PAPERLESS_SEARCH_TOKEN_OUT="$tmp" \
            paperless-manage shell -c '
import os
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from rest_framework.authtoken.models import Token

User = get_user_model()
user, _ = User.objects.get_or_create(username="search-service")
user.set_unusable_password()
user.is_staff = False
user.is_superuser = False
user.save()
group, _ = Group.objects.get_or_create(name="paperless-users")
user.groups.add(group)
token, _ = Token.objects.get_or_create(user=user)
with open(os.environ["PAPERLESS_SEARCH_TOKEN_OUT"], "w") as handle:
    handle.write(token.key)
'

          install -m 0640 -o root -g search "$tmp" ${tokenFile}
        '';
      };
    });
}
