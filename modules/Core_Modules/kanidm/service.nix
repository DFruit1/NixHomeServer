{ config, lib, pkgs, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  kanidmPort = vars.networking.ports.kanidm;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  oauth2ClientsForConsentPrompt = lib.filterAttrs
    (_name: client: (client.present or true) && !(client.public or false))
    config.services.kanidm.provision.systems.oauth2;
  disableConsentCommands = lib.concatStringsSep "\n"
    (map
      (clientName: ''
        ${pkgs.kanidm_1_10}/bin/kanidm system oauth2 disable-consent-prompt \
          -H ${kanidmCliUrl} \
          -D idm_admin \
          ${lib.escapeShellArg clientName}
      '')
      (builtins.attrNames oauth2ClientsForConsentPrompt));
  operatorBootstrap = pkgs.writeShellApplication {
    name = "kanidm-operator-bootstrap";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      kanidm_1_10
    ];
    text = ''
            set -euo pipefail
            umask 077

            usage() {
              cat <<'EOF'
      Usage:
        sudo kanidm-operator-bootstrap status
        sudo kanidm-operator-bootstrap issue [--ttl <seconds>] [--recovery]

      `status` reports whether the configured delegated operator has a credential.
      `issue` prints a short-lived reset URL without storing it. Once an operator
      already has credentials, --recovery is required to issue another URL.
      EOF
            }

            action="''${1:-}"
            [[ -n "$action" ]] || { usage >&2; exit 1; }
            if [[ "$action" == -h || "$action" == --help ]]; then
              usage
              exit 0
            fi
            if [[ "$EUID" -ne 0 ]]; then
              echo "blocked: this command must run as root so the managed idm_admin credential remains protected" >&2
              exit 1
            fi
            shift
            ttl=3600
            ttl_set=false
            recovery=false
            while (($# > 0)); do
              case "$1" in
                --ttl)
                  [[ $# -ge 2 ]] || { echo "blocked: --ttl requires seconds" >&2; exit 1; }
                  ttl="$2"
                  ttl_set=true
                  shift 2
                  ;;
                --recovery)
                  recovery=true
                  shift
                  ;;
                -h|--help)
                  usage
                  exit 0
                  ;;
                *)
                  echo "blocked: unknown argument: $1" >&2
                  usage >&2
                  exit 1
                  ;;
              esac
            done

            if [[ ! "$ttl" =~ ^[0-9]+$ ]] || ((ttl < 300 || ttl > 86400)); then
              echo "blocked: --ttl must be between 300 and 86400 seconds" >&2
              exit 1
            fi
            case "$action" in
              status)
                [[ "$ttl_set" == false && "$recovery" == false ]] || {
                  echo "blocked: status does not accept issue options" >&2
                  exit 1
                }
                ;;
              issue)
                ;;
              *)
                echo "blocked: action must be status or issue" >&2
                usage >&2
                exit 1
                ;;
            esac

            secret=${lib.escapeShellArg config.age.secrets.kanidmAdminPass.path}
            [[ -f "$secret" && ! -L "$secret" && -s "$secret" ]] || {
              echo "blocked: managed idm_admin credential is unavailable" >&2
              exit 1
            }

            HOME="$(mktemp -d)"
            export HOME
            trap 'rm -rf "$HOME"' EXIT
            KANIDM_PASSWORD="$(tr -d '\r\n' <"$secret")"
            export KANIDM_PASSWORD
            kanidm login -H ${kanidmCliUrl} -D idm_admin >/dev/null
            kanidm person get -H ${kanidmCliUrl} -D idm_admin \
              ${lib.escapeShellArg vars.kanidmAdminUser} >/dev/null

            credential_status_error="$HOME/credential-status.error"
            credential_status="$(kanidm person credential status \
              -H ${kanidmCliUrl} \
              -D idm_admin \
              ${lib.escapeShellArg vars.kanidmAdminUser} 2>"$credential_status_error")"
            if [[ "$(head -n 1 <<<"$credential_status")" != "---" \
              || "$(tail -n 1 <<<"$credential_status")" != "---" ]]; then
              echo "blocked: Kanidm did not return a valid credential status for ${vars.kanidmAdminUser}" >&2
              sed 's/^/  /' "$credential_status_error" >&2
              exit 1
            fi
            if grep -q '^uuid:' <<<"$credential_status"; then
              has_credentials=true
            else
              has_credentials=false
            fi

            if [[ "$action" == status ]]; then
              if [[ "$has_credentials" == true ]]; then
                echo "configured operator ${vars.kanidmAdminUser} has an authentication credential"
              else
                echo "configured operator ${vars.kanidmAdminUser} has no authentication credential"
                echo "next step: sudo kanidm-operator-bootstrap issue"
              fi
              exit 0
            fi

            if [[ "$has_credentials" == true && "$recovery" != true ]]; then
              echo "blocked: operator already has credentials; use --recovery only for an intentional account recovery" >&2
              exit 1
            fi

            echo "The following reset URL is an active secret valid for $ttl seconds." >&2
            echo "Send it only through a trusted channel and do not paste it into logs or tickets." >&2
            reset_error="$HOME/reset-token.error"
            reset_output="$(kanidm person credential create-reset-token \
              -H ${kanidmCliUrl} \
              -D idm_admin \
              --ttl "$ttl" \
              ${lib.escapeShellArg vars.kanidmAdminUser} 2>"$reset_error")"
            reset_link="$(sed -n 's/^This link: //p' <<<"$reset_output")"
            case "$reset_link" in
              ${lib.escapeShellArg "${kanidmCliUrl}/ui/reset?token="}?*)
                ;;
              *)
                echo "blocked: Kanidm did not return a usable reset URL" >&2
                sed 's/^/  /' "$reset_error" >&2
                exit 1
                ;;
            esac
            public_reset_link=${lib.escapeShellArg vars.kanidmBaseUrl}"''${reset_link#${lib.escapeShellArg kanidmCliUrl}}"
            printf '%s\n' "$public_reset_link"
    '';
  };
in
{
  services.kanidm = {
    server.enable = true;
    client.enable = true;
    client.settings.uri = vars.kanidmBaseUrl;
    package = pkgs.kanidmWithSecretProvisioning_1_10;

    server.settings = {
      origin = "https://${vars.kanidmDomain}";
      domain = vars.domain;
      bindaddress = "${loopback}:${toString kanidmPort}";

      tls_chain = "/var/lib/acme/${vars.kanidmDomain}/fullchain.pem";
      tls_key = "/var/lib/acme/${vars.kanidmDomain}/key.pem";

      online_backup = {
        path = "/var/lib/kanidm/backups";
        schedule = "00 02 * * *";
        versions = 7;
      };
    };
  };

  environment.systemPackages = [ operatorBootstrap ];

  systemd.services.kanidm = {
    after = [
      "caddy.service"
      "acme-${vars.kanidmDomain}.service"
    ];
    wants = [
      "caddy.service"
      "acme-${vars.kanidmDomain}.service"
    ];
  };

  systemd.services.kanidm-disable-consent-prompt = lib.mkIf (oauth2ClientsForConsentPrompt != { }) {
    description = "Disable Kanidm consent prompt for configured OAuth2 clients";
    wantedBy = [ "multi-user.target" ];
    after = [ "kanidm.service" ];
    wants = [ "kanidm.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "10s";
    };
    script = ''
      set -euo pipefail

      export HOME="$(mktemp -d)"
      trap 'rm -rf "$HOME"' EXIT
      KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmAdminPass.path})"
      export KANIDM_PASSWORD

      ${pkgs.kanidm_1_10}/bin/kanidm login -H ${kanidmCliUrl} -D idm_admin >/dev/null

      ${disableConsentCommands}
    '';
  };

  users.users.kanidm.extraGroups = [ "caddy" ];

  systemd.tmpfiles.rules = [
    "d /var/lib/kanidm 0700 kanidm kanidm -"
    "d /var/lib/kanidm/backups 0700 kanidm kanidm -"
  ];
}
