{ vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  host = "files.${vars.domain}";
  transfersHost = "transfers.${vars.domain}";
  # The transfers host deliberately bypasses oauth2-proxy so anonymous visitors
  # can open share links. It proxies straight to Filestash while rewriting the
  # Host header to `files.` so the SecureOrigin middleware and any configured
  # general.host logic stay on the expected hostname. Proxy-authentication
  # headers are stripped so share visitors cannot forge their way into the main
  # file UI. The same proxy block is used behind every allowlisted public route
  # below.
  filestashProxy = ''
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
  # The public share host is default-deny. A share visitor only needs the share
  # frontend, the static SPA bundle, the public config/session read endpoints,
  # share proof submission, and share-scoped file/export access. Sensitive
  # surfaces -- the admin console, `/api/backend`, session authentication,
  # `/api/share` list/upsert/delete, and non-share file or API-key access -- are
  # never reachable from the public origin.
  transfersExtraConfig = ''
    # Force active content to download and stop MIME sniffing, mirroring the
    # hardening applied to the authenticated `files.` host.
    @download_html_svg path *.html *.svg
    header @download_html_svg Content-Disposition attachment
    header @download_html_svg X-Content-Type-Options nosniff

    @transfers_frontend path / /index.html /s/* /files/* /view/* /tags/* /login /login/* /logout /logout/*
    @transfers_static path /assets/* /overrides/* /sw.js /favicon.ico /robots.txt /manifest.json /.well-known/* /custom.css /about /healthz
    @transfers_public_config path /api/config /api/plugin
    @transfers_session {
      path /api/session
      method GET DELETE
    }
    @transfers_share_proof path_regexp ^/api/share/[^/]+/proof$
    @transfers_share_files {
      path /api/files/* /api/onlyoffice/* /api/wopi/*
      query share=*
    }
    @transfers_share_export path /api/export/*

    handle @transfers_frontend {
      ${filestashProxy}
    }
    handle @transfers_static {
      ${filestashProxy}
    }
    handle @transfers_public_config {
      ${filestashProxy}
    }
    handle @transfers_session {
      ${filestashProxy}
    }
    handle @transfers_share_proof {
      ${filestashProxy}
    }
    handle @transfers_share_files {
      ${filestashProxy}
    }
    handle @transfers_share_export {
      ${filestashProxy}
    }
    handle {
      respond "Not Found" 404
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

  # Public share-link host. It shares the standard HTTPS listener (port 443) so
  # generated links carry no non-standard port and stay reachable through
  # Cloudflare's proxy and from networks that block non-443 egress. It is a
  # distinct vhost that bypasses oauth2-proxy and reuses the wildcard
  # `*.${vars.domain}` certificate; the Core caddy module already opens port 443
  # on the LAN and Netbird interfaces.
  services.caddy.virtualHosts.${transfersHost} = {
    logFormat = null;
    useACMEHost = vars.domain;
    extraConfig = transfersExtraConfig;
  };

  services.unbound.privateHosts.${host} = {
    target = "private";
  };
  services.unbound.privateHosts.${transfersHost} = {
    target = "private";
  };
}
