{ config, filestashNix, lib, pkgs, vars, ... }:

let
  enabled = config.nixhomeserver.apps.files.enable;
  apps = config.nixhomeserver.apps;
  oauth2Proxy = import ../lib/oauth2-proxy.nix { inherit lib pkgs vars; };
  loopback = vars.networking.loopbackIPv4;
  filesPort = vars.filesPort;
  oauth2ProxyPort = vars.networking.ports.oauth2ProxyFilestash;
  stateDir = vars.filesStateDir;
  managedDir = "${stateDir}/.nixos-managed";
  secretRuntimeDir = "/run/filestash-secrets";
  secretKeyFile = "${managedDir}/secret-key";
  adminPasswordFile = "${managedDir}/admin-password";
  adminPasswordHashFile = "${managedDir}/admin-password.bcrypt";
  oauth2ClientSecretStateFile = "${managedDir}/oauth2-client-secret";
  oauth2CookieSecretStateFile = "${managedDir}/oauth2-cookie-secret";
  oauth2ClientSecretFile = "${secretRuntimeDir}/oauth2-client-secret";
  oauth2ClientSecretKanidmFile = "${secretRuntimeDir}/oauth2-client-secret-kanidm";
  oauth2CookieSecretFile = "${secretRuntimeDir}/oauth2-cookie-secret";
  filestashEnvironmentFile = "${secretRuntimeDir}/filestash.env";
  pythonWithBcrypt = pkgs.python3.withPackages (ps: [ ps.bcrypt ]);
  mkLocalBackend = path: {
    type = "local";
    inherit path;
    password = "{{ .ENV_LOCAL_BACKEND_SECRET }}";
  };
  localBackendMappings = {
    Personal = mkLocalBackend vars.usersRoot;
    Shared = mkLocalBackend vars.sharedRoot;
  }
  // lib.optionalAttrs apps.copyparty.enable {
    Quarantine = mkLocalBackend vars.uploadSecurity.quarantineRoot;
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
  ]
  ++ lib.optionals apps.copyparty.enable [
    {
      type = "local";
      label = "Quarantine";
      path = vars.uploadSecurity.quarantineRoot;
    }
  ];
in
{
  imports = [
    filestashNix.nixosModules.filestash
    ./filepaths.nix
    ./identity.nix
    ./backups.nix
    ./networking.nix
  ];

  config = lib.mkIf enabled (lib.mkMerge [
    {
      services.filestash = {
        enable = true;
        settings = {
          general = {
            name = "Filestash";
            port = filesPort;
            host = vars.filesDomain;
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
              related_backend = lib.concatStringsSep "," (map (connection: connection.label) localBackendConnections);
              params = builtins.toJSON localBackendMappings;
            };
          };
          connections = localBackendConnections;
        };
      };

      users.users.filestash.extraGroups = [
        "users"
      ]
      ++ lib.optionals apps.audiobookshelf.enable [ "audiobookshelf-media" ]
      ++ lib.optionals apps.kavita.enable [ "kavita-media" ]
      ++ lib.optionals apps.jellyfin.enable [ "jellyfin-media" ]
      ++ lib.optionals apps.kiwix.enable [ "kiwix" ]
      ++ lib.optionals apps.copyparty.enable [ "upload-review" ];

      systemd.tmpfiles.rules = [
        "d ${managedDir} 0750 root filestash -"
      ];

      systemd.services.filestash-secret-materialize = {
        description = "Materialize Filestash runtime secrets";
        wantedBy = [ "multi-user.target" ];
        before = [
          "filestash.service"
          "filestash-oauth2-proxy.service"
          "kanidm.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [
          pkgs.coreutils
          pkgs.openssl
          pythonWithBcrypt
        ];
        script = ''
                    set -euo pipefail

                    install -d -m 0750 -o root -g filestash ${lib.escapeShellArg managedDir}
          install -d -m 0755 -o root -g root ${lib.escapeShellArg secretRuntimeDir}

                    generate_secret() {
                      local path="$1"
                      local generator="$2"
                      if [ ! -s "$path" ]; then
                        umask 0077
                        eval "$generator" > "$path"
                      fi
                    }

                    generate_secret ${lib.escapeShellArg secretKeyFile} \
                      "${pythonWithBcrypt}/bin/python -c 'import secrets,string; alphabet = string.ascii_letters + string.digits; print(\"\".join(secrets.choice(alphabet) for _ in range(16)))'"
                    generate_secret ${lib.escapeShellArg adminPasswordFile} "openssl rand -base64 24"
          generate_secret ${lib.escapeShellArg oauth2ClientSecretStateFile} "openssl rand -hex 32 | tr -d '\n'"
          generate_secret ${lib.escapeShellArg oauth2CookieSecretStateFile} "openssl rand -hex 16 | tr -d '\n'"

          oauth2_client_secret_normalized="$(tr -d '\r\n' < ${lib.escapeShellArg oauth2ClientSecretStateFile})"
          printf '%s' "$oauth2_client_secret_normalized" > ${lib.escapeShellArg oauth2ClientSecretStateFile}

          cookie_secret_size="$(wc -c < ${lib.escapeShellArg oauth2CookieSecretStateFile})"
          case "$cookie_secret_size" in
            16|24|32) ;;
            *)
              umask 0077
              openssl rand -hex 16 | tr -d '\n' > ${lib.escapeShellArg oauth2CookieSecretStateFile}
              ;;
          esac

          ${pythonWithBcrypt}/bin/python - <<'PY'
          from pathlib import Path
          import bcrypt

          password = Path(${builtins.toJSON adminPasswordFile}).read_bytes().strip()
          hash_path = Path(${builtins.toJSON adminPasswordHashFile})
          hash_path.write_text(bcrypt.hashpw(password, bcrypt.gensalt(rounds=12)).decode() + "\n")
          PY

                    chown root:root ${lib.escapeShellArg adminPasswordFile}
                    chmod 0400 ${lib.escapeShellArg adminPasswordFile}
                    chown root:filestash ${lib.escapeShellArg secretKeyFile} ${lib.escapeShellArg adminPasswordHashFile}
                    chmod 0440 ${lib.escapeShellArg secretKeyFile} ${lib.escapeShellArg adminPasswordHashFile}
                    chown root:root ${lib.escapeShellArg oauth2ClientSecretStateFile} ${lib.escapeShellArg oauth2CookieSecretStateFile}
                    chmod 0400 ${lib.escapeShellArg oauth2ClientSecretStateFile} ${lib.escapeShellArg oauth2CookieSecretStateFile}

                    install -m 0440 -o root -g oauth2-proxy ${lib.escapeShellArg oauth2ClientSecretStateFile} ${lib.escapeShellArg oauth2ClientSecretFile}
                    install -m 0440 -o root -g kanidm ${lib.escapeShellArg oauth2ClientSecretStateFile} ${lib.escapeShellArg oauth2ClientSecretKanidmFile}
                    install -m 0440 -o root -g oauth2-proxy ${lib.escapeShellArg oauth2CookieSecretStateFile} ${lib.escapeShellArg oauth2CookieSecretFile}

                    local_backend_secret="$(tr -d '\r\n' < ${lib.escapeShellArg adminPasswordFile})"
                    printf 'LOCAL_BACKEND_SECRET=%s\n' "$local_backend_secret" > ${lib.escapeShellArg filestashEnvironmentFile}
                    chown root:filestash ${lib.escapeShellArg filestashEnvironmentFile}
                    chmod 0440 ${lib.escapeShellArg filestashEnvironmentFile}
        '';
      };

      systemd.services.filestash = {
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
          ]
          ++ lib.optionals apps.kiwix.enable [ vars.kiwixLibraryRoot ]
          ++ lib.optionals apps.copyparty.enable [ vars.uploadSecurity.quarantineRoot ];
          UMask = "0007";
        };
      };

      systemd.services.kanidm = {
        wants = [ "filestash-secret-materialize.service" ];
        after = [ "filestash-secret-materialize.service" ];
      };
    }

    (oauth2Proxy.mkSidecarService {
      serviceName = "filestash-oauth2-proxy";
      description = "Dedicated OAuth2 Proxy for Filestash";
      clientId = "filestash-web";
      clientSecretFile = oauth2ClientSecretFile;
      cookieSecretFile = oauth2CookieSecretFile;
      cookieName = "_oauth2_proxy_filestash";
      domain = vars.filesDomain;
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
  ]);
}
