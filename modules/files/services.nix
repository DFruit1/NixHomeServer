{ filestashNix, lib, oauth2Proxy, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  filesPort = vars.filesPort;
  oauth2ProxyPort = vars.networking.ports.oauth2ProxyFilestash;
  host = "files.${vars.domain}";
  stateDir = vars.filesStateDir;
  managedDir = "${stateDir}/.nixos-managed";
  secretRuntimeDir = "/run/filestash-secrets";
  secretKeyFile = "${managedDir}/secret-key";
  adminPasswordHashFile = "${managedDir}/admin-password.bcrypt";
  oauth2ClientSecretFile = "${secretRuntimeDir}/oauth2-client-secret";
  oauth2CookieSecretFile = "${secretRuntimeDir}/oauth2-cookie-secret";
  filestashEnvironmentFile = "${secretRuntimeDir}/filestash.env";
  mkLocalBackend = path: {
    type = "local";
    inherit path;
    password = "{{ .ENV_LOCAL_BACKEND_SECRET }}";
  };
  localBackendMappings = {
    Personal = mkLocalBackend vars.usersRoot;
    Shared = mkLocalBackend vars.sharedRoot;
  };
  localBackendConnections = [
    {
      type = "local";
      label = "Personal";
      path = vars.usersRoot;
    }
    {
      type = "local";
      label = "Shared";
      path = vars.sharedRoot;
    }
  ];
in
{
  imports = [
    filestashNix.nixosModules.filestash
  ];

  config = lib.mkMerge [
    {
      services.filestash = {
        enable = true;
        settings = {
          general = {
            name = "Filestash";
            port = filesPort;
            host = host;
            force_ssl = true;
            logout = "/oauth2/sign_out?rd=/oauth2/start?rd=%2F";
            upload_button = true;
            refresh_after_upload = true;
            cookie_timeout = vars.filesSessionExpirationHours * 60;
            secret_key_file = secretKeyFile;
          };
          features = {
            api.enable = true;
            share.enable = true;
            protection.enable_chromecast = false;
          };
          log = {
            enable = true;
            level = "INFO";
            telemetry = false;
          };
          email = { };
          auth.admin_file = adminPasswordHashFile;
          middleware = {
            identity_provider = {
              type = "passthrough";
              params = builtins.toJSON {
                strategy = "direct";
              };
            };
            attribute_mapping = {
              related_backend = lib.mkDefault (lib.concatStringsSep "," (map (connection: connection.label) localBackendConnections));
              params = lib.mkDefault (builtins.toJSON localBackendMappings);
            };
          };
          connections = lib.mkDefault localBackendConnections;
        };
      };

      systemd.services.filestash = {
        requires = [
          "filestash-secret-materialize.service"
        ];
        wants = [
          "data-pool-layout.service"
          "fileshare-user-root-sync.service"
          "filestash-secret-materialize.service"
          "network-online.target"
        ];
        after = [
          "data-pool-layout.service"
          "fileshare-user-root-sync.service"
          "filestash-secret-materialize.service"
          "network-online.target"
        ];
        preStart = lib.mkAfter ''
          chmod 0640 "$RUNTIME_DIRECTORY"/config.json
        '';
        serviceConfig = {
          Environment = [
            "CONFIG_ENCRYPT=false"
          ];
          EnvironmentFile = filestashEnvironmentFile;
          NoNewPrivileges = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectProc = "invisible";
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          LockPersonality = true;
          RemoveIPC = true;
          RestrictSUIDSGID = true;
          RestrictRealtime = true;
          ReadWritePaths = [
            stateDir
            "/var/cache/filestash"
            "/var/log/filestash"
            vars.usersRoot
            vars.sharedRoot
          ];
          UMask = "0007";
        };
      };

    }

    (oauth2Proxy.mkSidecarService {
      serviceName = "filestash-oauth2-proxy";
      description = "Dedicated OAuth2 Proxy for Filestash";
      clientId = "filestash-web";
      clientSecretFile = oauth2ClientSecretFile;
      cookieSecretFile = oauth2CookieSecretFile;
      cookieName = "_oauth2_proxy_filestash";
      domain = host;
      port = oauth2ProxyPort;
      upstream = "http://${loopback}:${toString filesPort}";
      allowedGroups = [ "user-files" ];
      serviceDependencies = [
        "caddy.service"
        "filestash.service"
        "filestash-secret-materialize.service"
      ];
      upstreamCheck = {
        displayName = "Filestash";
        url = "http://${loopback}:${toString filesPort}/";
      };
      extraProxyArgs = [
        "--session-cookie-minimal=true"
        "--skip-auth-preflight=true"
        "--upstream-timeout=30m0s"
      ];
    })
  ];
}
