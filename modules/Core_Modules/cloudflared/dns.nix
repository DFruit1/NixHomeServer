{ config, lib, pkgs, vars, ... }:

# Keep the Cloudflare-side DNS records for the tunnel in sync with the hosts
# declared in `services.cloudflared.tunnels.<name>.ingress`. The NixOS
# cloudflared module configures the tunnel ingress locally but does not create
# the public CNAME records that point a hostname at the tunnel, so they are
# reconciled here through the Cloudflare API using the existing agenix
# `cfAPIToken` and the tunnel id from `cfHomeCreds`. The sync is idempotent:
# records that already point at the tunnel are left untouched.

let
  tunnelName = vars.cloudflareTunnelName;
  ingress = config.services.cloudflared.tunnels.${tunnelName}.ingress;
  hosts = builtins.filter
    (host: host != "default" && (host == vars.domain || lib.hasSuffix ".${vars.domain}" host))
    (builtins.attrNames ingress);

  syncScript = pkgs.writeShellApplication {
    name = "cloudflare-dns-sync";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.coreutils
    ];
    text = ''
      token_file=${lib.escapeShellArg config.age.secrets.cfAPIToken.path}
      creds_file=${lib.escapeShellArg config.age.secrets.cfHomeCreds.path}
      zone_name=${lib.escapeShellArg vars.domain}
      api=https://api.cloudflare.com/client/v4

      curl_json() {
        curl -s --max-time 20 --retry 4 --retry-delay 3 --retry-connrefused \
          -H "Authorization: Bearer $token" -H 'Content-Type: application/json' "$@"
      }

      token="$(tr -d '\r\n' < "$token_file")"
      tunnel_id="$(jq -r '.TunnelID // .tunnel_id // empty' "$creds_file")"
      if [ -z "$tunnel_id" ]; then
        echo "cloudflare-dns-sync: could not read the tunnel id from $creds_file" >&2
        exit 1
      fi
      target="$tunnel_id.cfargotunnel.com"

      zone_lookup="$(curl_json "$api/zones?name=$zone_name")"
      zone_id="$(jq -r '.result[0].id // empty' <<<"$zone_lookup")"
      if [ -z "$zone_id" ]; then
        echo "cloudflare-dns-sync: could not resolve zone $zone_name: $(jq -c '.errors' <<<"$zone_lookup")" >&2
        exit 1
      fi

      hosts=(
${lib.concatMapStringsSep "\n" (host: "        ${lib.escapeShellArg host}") hosts}
      )

      for host in "''${hosts[@]}"; do
        existing="$(curl_json "$api/zones/$zone_id/dns_records?name=$host")"
        count="$(jq '.result | length' <<<"$existing")"
        if [ "$count" = "1" ]; then
          type="$(jq -r '.result[0].type' <<<"$existing")"
          content="$(jq -r '.result[0].content' <<<"$existing")"
          proxied="$(jq -r '.result[0].proxied' <<<"$existing")"
          record_id="$(jq -r '.result[0].id' <<<"$existing")"
          if [ "$type" = "CNAME" ] && [ "$content" = "$target" ] && [ "$proxied" = "true" ]; then
            echo "ok: $host already points at $target"
            continue
          fi
          payload="$(jq -nc --arg n "$host" --arg c "$target" '{type:"CNAME",name:$n,content:$c,proxied:true,ttl:1}')"
          response="$(curl_json -X PUT --data "$payload" "$api/zones/$zone_id/dns_records/$record_id")"
        elif [ "$count" = "0" ]; then
          payload="$(jq -nc --arg n "$host" --arg c "$target" '{type:"CNAME",name:$n,content:$c,proxied:true,ttl:1}')"
          response="$(curl_json -X POST --data "$payload" "$api/zones/$zone_id/dns_records")"
        else
          echo "cloudflare-dns-sync: multiple records exist for $host; leaving untouched" >&2
          continue
        fi

        if [ "$(jq -r '.success' <<<"$response")" != "true" ]; then
          echo "cloudflare-dns-sync: failed to sync $host: $(jq -c '.errors' <<<"$response")" >&2
          exit 1
        fi
        echo "synced: $host -> $target"
      done
    '';
  };
in
{
  systemd.services.cloudflare-dns-sync = {
    description = "Ensure Cloudflare DNS records exist for every tunnel ingress host";
    wantedBy = [ "multi-user.target" ];
    # The API host is resolved through the local Unbound resolver, so wait for
    # it to listen before the first curl; network-online.target alone can be
    # reached before Unbound is up and then every lookup fails.
    wants = [ "network-online.target" "unbound.service" ];
    after = [ "network-online.target" "unbound.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe syncScript;
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
    };
  };
}
