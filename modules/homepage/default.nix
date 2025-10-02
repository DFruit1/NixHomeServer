{ lib, vars, ... }:

{
  users.groups."homepage-dashboard" = { };

  users.users."homepage-dashboard" = {
    isSystemUser = true;
    group = "homepage-dashboard";
    home = "/var/lib/homepage-dashboard";
  };

  services.homepage-dashboard = {
    enable = true;
    listenPort = vars.homepagePort; # 3005
    openFirewall = false;
    allowedHosts =
      "${vars.domain},www.${vars.domain},localhost:${toString vars.homepagePort},127.0.0.1:${toString vars.homepagePort}";

    ## ────────────────────────────────────────────────────────
    ## 1.  Bookmarks (grouped lists of name→URL)
    ## ────────────────────────────────────────────────────────
    bookmarks = [
      {
        Developer = {
          GitHub = "https://github.com";
          "NixOS Manual" = "https://nixos.org/manual/nixos/stable/";
          "Kanidm Docs" = "https://kanidm.github.io/kanidm/";
        };
      }
      {
        Infrastructure = {
          "Cloudflare Dash" = "https://dash.cloudflare.com";
          Router = "http://192.168.1.1";
          "NetBird Admin" = "https://app.netbird.io";
        };
      }
      {
        Learning = {
          "Rust Book" = "https://doc.rust-lang.org/book/";
          "QGIS Docs" = "https://docs.qgis.org/";
        };
      }
    ];

    ## ────────────────────────────────────────────────────────
    ## 2.  Services (grouped panels with icons, health-checks, etc.)
    ## ────────────────────────────────────────────────────────
    services = [
      {
        Infrastructure = {
          Caddy = {
            icon = "caddy";
            href = "https://${vars.domain}";
            server = vars.domain;
            statusCheck = "http";
            description = "Public reverse-proxy & ACME endpoint";
          };
          Kanidm = {
            icon = "shield";
            href = "https://${vars.kanidmDomain}";
            server = vars.kanidmDomain;
            statusCheck = "http";
            description = "Identity (OIDC/LDAP) server";
          };
        };
      }
      {
        Media = {
          Immich = {
            icon = "image";
            href = "https://immich.${vars.domain}";
            server = "immich.${vars.domain}";
            statusCheck = "http";
          };
          Audiobookshelf = {
            icon = "book";
            href = "https://audiobookshelf.${vars.domain}";
            server = "audiobookshelf.${vars.domain}";
            statusCheck = "http";
          };
        };
      }
      {
        Storage = {
          Paperless = {
            icon = "file-document";
            href = "https://paperless.${vars.domain}";
            statusCheck = "http";
          };
          Vaultwarden = {
            icon = "vault";
            href = "https://vault.${vars.domain}";
            statusCheck = "http";
          };
          Copyparty = {
            icon = "upload";
            href = "https://fileshare.${vars.domain}";
            server = "fileshare.${vars.domain}";
            statusCheck = "http";
          };
        };
      }
    ];

    ## ────────────────────────────────────────────────────────
    ## 3.  Widgets (info, metrics, pings)
    ## ────────────────────────────────────────────────────────
    widgets = [
      {
        datetime = {
          format = "dddd, MMMM D — HH:mm";
          locale = "en-AU";
        };
      }
      {
        weather = {
          label = "Sydney";
          provider = "openweathermap";
          latitude = -33.87;
          longitude = 151.21;
          units = "metric";
          apikey = "{{HOMEPAGE_VAR_OWM}}"; # put in .env if you like
        };
      }
      {
        system = {
          title = "Server";
          show = [ "cpu" "mem" "load" "uptime" ];
          refresh = 30;
          hostname = vars.hostname;
        };
      }
      {
        ping = {
          targets = {
            Router = "192.168.1.1";
            Cloudflare = "1.1.1.1";
            NetBird = vars.nbIP;
          };
        };
      }
    ];

    ## ────────────────────────────────────────────────────────
    ## 4.  Layout & theme settings
    ## ────────────────────────────────────────────────────────
    settings = {
      title = "Sydney Basin Home Server";
      theme = "dark"; # or "light"
      color = "indigo"; # primary accent
      fullWidth = true; # stretch to browser width
      maxGroupColumns = 3; # bookmarks & services
      groupsInitiallyCollapsed = false; # start expanded
      layout = {
        Infrastructure = { style = "row"; columns = 2; };
        Media = { style = "row"; columns = 2; };
        Storage = { style = "row"; columns = 2; };
      };
    };

    ## ────────────────────────────────────────────────────────
    ## 5.  Custom styling & scripting
    ## ────────────────────────────────────────────────────────
    # customCSS = ./dotfiles/custom.css;
    # customJsFile = ./dotfiles/custom.js;

    ## ────────────────────────────────────────────────────────
    ## 6.  Secrets (if you want to stash API keys in a .env)
    ## ────────────────────────────────────────────────────────
    # environmentFile = ./dotfiles/.env;
  };

  systemd.services.homepage-dashboard.environment.HOMEPAGE_BIND_ADDRESS = "127.0.0.1";
  systemd.services.homepage-dashboard.serviceConfig = {
    AppArmorProfile = "generated-homepage-dashboard";
    DynamicUser = lib.mkForce false;
    User = "homepage-dashboard";
    Group = "homepage-dashboard";
    StateDirectory = lib.mkForce "homepage-dashboard";
    CacheDirectory = lib.mkForce "homepage-dashboard";
    LogsDirectory = lib.mkForce "homepage-dashboard";
  };
}
