{ vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  host = "files.${vars.domain}";
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

  services.unbound.privateHosts.${host} = {
    target = "private";
  };
}
