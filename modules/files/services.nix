{ config, filestashNix, lib, oauth2Proxy, pkgs, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  filesPort = vars.networking.ports.filestash;
  oauth2ProxyPort = vars.networking.ports.oauth2ProxyFilestash;
  host = "files.${vars.domain}";
  stateDir = config.repo.files.paths.stateDir;
  managedDir = "${stateDir}/.nixos-managed";
  secretRuntimeDir = "/run/filestash-secrets";
  secretKeyFile = "${managedDir}/secret-key";
  sftpClientKeyFile = "${managedDir}/sftp-client-key";
  adminPasswordHashFile = "${managedDir}/admin-password.bcrypt";
  oauth2ClientSecretFile = "${secretRuntimeDir}/oauth2-client-secret";
  oauth2CookieSecretFile = "${secretRuntimeDir}/oauth2-cookie-secret";
  webAccessGroup = vars.fileAccess.webAccessGroup or "files-personal-users";
  webAccessGroups = [ webAccessGroup ];
  proxyUserHeader = "X-Auth-Request-Preferred-Username";
  proxyEmailHeader = "X-Auth-Request-Email";
  proxyGroupsHeader = "X-Auth-Request-Groups";
  filesSftpPort = vars.networking.ports.filesSftp;
  adminMailAddresses =
    if vars.kanidmAdminMailAddresses != [ ] then
      vars.kanidmAdminMailAddresses
    else
      [ vars.kanidmAdminEmail ];
  filestashLoginUsers = lib.unique (
    (vars.kanidmAppUsers or [ ])
    ++ (vars.filesSftpUsers or [ ])
  );
  sftpLoginUserEmailEntries =
    lib.flatten (map
      (user:
        let
          mailAddresses =
            if user == vars.kanidmAdminUser then
              adminMailAddresses
            else if builtins.hasAttr user vars.kanidmAppUserEmails then
              [ vars.kanidmAppUserEmails.${user} ]
            else
              [ ];
        in
        map
          (mail: {
            inherit user mail;
          })
          mailAddresses)
      filestashLoginUsers);
  sftpLoginUserEmailMapGo = lib.concatMapStringsSep "\n"
    (entry:
      "    ${builtins.toJSON (lib.toLower entry.mail)}: ${builtins.toJSON entry.user},"
    )
    sftpLoginUserEmailEntries;
  filestashPackages = import ./package.nix {
    inherit lib pkgs vars sftpClientKeyFile sftpLoginUserEmailMapGo;
  };
  filestashPackage = filestashPackages.default;
  officePluginArchive = filestashPackages.officePluginArchive;
  sftpBackendMappings = {
    Files = {
      type = "sftp";
      hostname = loopback;
      port = toString filesSftpPort;
      username = "{{ .sftp_user }}";
      password = "{{ .sftp_private_key }}";
      path = "";
    };
  };
  sftpBackendConnections = [
    {
      type = "sftp";
      label = "Files";
      hostname = loopback;
      port = toString filesSftpPort;
      path = "";
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
        package = filestashPackage;
        settings = {
          general = {
            name = "Filestash";
            port = filesPort;
            host = host;
            force_ssl = true;
            logout = "/oauth2/sign_out";
            upload_button = true;
            refresh_after_upload = true;
            cookie_timeout = vars.filesSessionExpirationHours * 60;
            secret_key_file = secretKeyFile;
          };
          features = {
            api.enable = true;
            share = {
              enable = true;
              # Upstream defaults new links to `editor` (anonymous read, write,
              # and upload). Default to read-only and require an explicit choice
              # for write access on the public share host.
              default_access = "viewer";
            };
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
              type = "proxy_password";
              params = builtins.toJSON {
                user_header = proxyUserHeader;
                email_header = proxyEmailHeader;
                groups_header = proxyGroupsHeader;
              };
            };
            attribute_mapping = {
              related_backend = lib.mkDefault (lib.concatStringsSep "," (map (connection: connection.label) sftpBackendConnections));
              params = lib.mkDefault (builtins.toJSON sftpBackendMappings);
            };
          };
          connections = lib.mkDefault sftpBackendConnections;
        };
      };

      systemd.services.filestash = {
        requires = [
          "data-pool-layout.service"
          "files-sftp-sshd.service"
          "fileshare-user-root-sync.service"
          "filestash-secret-materialize.service"
        ];
        wants = [
          "network-online.target"
        ];
        after = [
          "data-pool-layout.service"
          "files-sftp-sshd.service"
          "fileshare-user-root-sync.service"
          "filestash-secret-materialize.service"
          "network-online.target"
        ];
        unitConfig = lib.mkIf vars.dataRootIsMountPoint {
          ConditionPathIsMountPoint = vars.dataRoot;
        };
        preStart = lib.mkAfter ''
          install -m 0444 ${officePluginArchive} \
            ${lib.escapeShellArg "${config.services.filestash.paths.plugins}/application_office.zip"}
          chmod 0640 "$RUNTIME_DIRECTORY"/config.json
        '';
        serviceConfig = {
          Environment = [
            "CONFIG_ENCRYPT=false"
          ];
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
      allowedGroups = webAccessGroups;
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
