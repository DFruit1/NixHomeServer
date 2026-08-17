{ lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  host = "files.${vars.domain}";
  transfersHost = "transfers.${vars.domain}";
  transfersPort = vars.networking.ports.filestashTransfers;
  netbirdIface = vars.networking.interfaces.netbird;
  lanIface = vars.networking.interfaces.lan;
  splitDnsMode = vars.networking.dns.mode == "split-horizon";
  # The transfers host deliberately bypasses oauth2-proxy so anonymous visitors
  # can open share links. It proxies straight to Filestash while rewriting the
  # Host header to `files.` so the SecureOrigin middleware and any configured
  # general.host logic stay on the expected hostname. Proxy-authentication
  # headers are stripped so share visitors cannot forge their way into the main
  # file UI.
  transfersReverseProxy = ''
    reverse_proxy http://${loopback}:${toString vars.networking.ports.filestash} {
      header_up Host ${host}
      header_up -X-Auth-Request-User
      header_up -X-Auth-Request-Email
      header_up -X-Auth-Request-Groups
      header_up -X-Auth-Request-Preferred-Username
      header_up -X-Forwarded-User
      header_up -X-Forwarded-Email
      header_up -X-Forwarded-Groups
      header_up -X-Forwarded-Preferred-Username
      header_up X-Forwarded-Proto https
    }
  '';
in
{
  services.caddy.virtualHosts.${host} = {
    logFormat = null;
    useACMEHost = vars.domain;
    extraConfig = ''
      @download_html_svg path *.html *.svg
      header @download_html_svg Content-Disposition attachment
      header @download_html_svg X-Content-Type-Options nosniff
      reverse_proxy http://${loopback}:${toString vars.networking.ports.oauth2ProxyFilestash} {
        header_up -X-Auth-Request-User
        header_up -X-Auth-Request-Email
        header_up -X-Auth-Request-Groups
        header_up -X-Auth-Request-Preferred-Username
        header_up -X-Forwarded-User
        header_up -X-Forwarded-Email
        header_up -X-Forwarded-Groups
        header_up -X-Forwarded-Preferred-Username
        header_up X-Forwarded-Proto https
      }
    '';
  };

  # Public share-link host on a dedicated listener. Served outside the tunnel on
  # the LAN/Netbird via the advertised port and via the Cloudflare tunnel with an
  # origin server name override. Reuses the wildcard `*.${vars.domain}` cert.
  services.caddy.virtualHosts."${transfersHost}:${toString transfersPort}" = {
    logFormat = null;
    useACMEHost = vars.domain;
    extraConfig = transfersReverseProxy;
  };

  services.unbound.privateHosts.${host} = {
    target = "private";
  };
  services.unbound.privateHosts.${transfersHost} = {
    target = "private";
  };

  networking.firewall.interfaces.${netbirdIface}.allowedTCPPorts = [
    (lib.mkAfter transfersPort)
  ];
  networking.firewall.interfaces.${lanIface}.allowedTCPPorts = lib.mkIf splitDnsMode [
    (lib.mkAfter transfersPort)
  ];
}