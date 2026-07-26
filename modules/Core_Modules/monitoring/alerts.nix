{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.monitoring.failureAlerts;
  targetUnit = "nixhomeserver-failure-alert@%n.service";
  alertScript = pkgs.writeShellApplication {
    name = "nixhomeserver-failure-alert";
    runtimeInputs = with pkgs; [ coreutils curl jq systemd util-linux ];
    text = ''
      # OnFailure passes %n as the template instance. It is already the exact
      # unit name; unescaping it would incorrectly turn ordinary hyphens into
      # path separators (for example foo-bar.service -> foo/bar.service).
      unit="''${1:?systemd unit instance is required}"
      result="$(systemctl show --property=Result --value "$unit" 2>/dev/null || true)"
      message="NixHomeServer unit failed: $unit on ${vars.hostname} (result: ''${result:-unknown})"

      logger --tag nixhomeserver-failure-alert --priority daemon.alert -- \
        "$message"

      ${lib.optionalString (cfg.webhookUrlFile != null) ''
        timestamp="$(date --utc --iso-8601=seconds)"
        webhook_url="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/webhook-url")"
        case "$webhook_url" in
          https://*) ;;
          *)
            echo "Failure-alert webhook must use HTTPS" >&2
            exit 1
            ;;
        esac
        curl_url="''${webhook_url//\\/\\\\}"
        curl_url="''${curl_url//\"/\\\"}"
        curl_config="$(mktemp)"
        trap 'rm -f "$curl_config"' EXIT
        printf 'url = "%s"\n' "$curl_url" >"$curl_config"

        if [[ ${lib.escapeShellArg cfg.format} == ntfy ]]; then
          ${pkgs.curl}/bin/curl \
            --config "$curl_config" \
            --fail-with-body \
            --silent \
            --show-error \
            --retry 5 \
            --retry-all-errors \
            --retry-delay 5 \
            --connect-timeout 15 \
            --max-time 60 \
            --header "Title: NixHomeServer service failure" \
            --header "Priority: high" \
            --header "Tags: warning,server" \
            --data-binary "$message"
        else
          payload="$(${pkgs.jq}/bin/jq -nc \
            --arg event systemd-unit-failed \
            --arg host ${lib.escapeShellArg vars.hostname} \
            --arg unit "$unit" \
            --arg result "''${result:-unknown}" \
            --arg timestamp "$timestamp" \
            --arg message "$message" \
            '{event:$event,host:$host,unit:$unit,result:$result,timestamp:$timestamp,message:$message}')"
          ${pkgs.curl}/bin/curl \
            --config "$curl_config" \
            --fail-with-body \
            --silent \
            --show-error \
            --retry 5 \
            --retry-all-errors \
            --retry-delay 5 \
            --connect-timeout 15 \
            --max-time 60 \
            --header "Content-Type: application/json" \
            --data-binary "$payload"
        fi
      ''}
    '';
  };
in
{
  options.repo.monitoring.failureAlerts = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Record important systemd failures and deliver them to an optional HTTPS webhook.";
    };

    webhookUrlFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default =
        if builtins.hasAttr "failureAlertWebhookUrl" config.age.secrets
        then config.age.secrets.failureAlertWebhookUrl.path
        else null;
      description = "Root-readable file containing the full HTTPS webhook or ntfy topic URL.";
    };

    format = lib.mkOption {
      type = lib.types.enum [ "json" "ntfy" ];
      default = "json";
      description = "Webhook payload format. Use ntfy for a full ntfy topic URL.";
    };

    targetUnit = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = targetUnit;
      description = "Systemd OnFailure target used by monitored units.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services."nixhomeserver-failure-alert@" = {
      description = "Deliver failure alert for %I";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${alertScript}/bin/nixhomeserver-failure-alert %i";
        DynamicUser = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        UMask = "0077";
      } // lib.optionalAttrs (cfg.webhookUrlFile != null) {
        LoadCredential = [ "webhook-url:${cfg.webhookUrlFile}" ];
      };
    };
  };
}
