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
  usbAccessGroup = vars.fileAccess.usbAccessGroup or "usb-access";
  backupStorageAccessGroup = vars.backupAccess.storageGroup or "backup-admin";
  webAccessGroups = [
    webAccessGroup
    usbAccessGroup
    backupStorageAccessGroup
  ];
  proxyUserHeader = "X-Auth-Request-Preferred-Username";
  proxyEmailHeader = "X-Auth-Request-Email";
  proxyGroupsHeader = "X-Auth-Request-Groups";
  filesSftpPort = vars.networking.ports.filesSftp;
  adminMailAddresses =
    if vars.kanidmAdminMailAddresses != [ ] then
      vars.kanidmAdminMailAddresses
    else
      [ vars.kanidmAdminEmail ];
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
      vars.kanidmAppUsers);
  sftpLoginUserEmailMapGo = lib.concatMapStringsSep "\n"
    (entry:
      "    ${builtins.toJSON (lib.toLower entry.mail)}: ${builtins.toJSON entry.user},"
    )
    sftpLoginUserEmailEntries;
  filestashPackages = filestashNix.packages.${pkgs.stdenv.hostPlatform.system};
  proxyPasswordPlugin = pkgs.writeText "plg_authenticate_proxy_password.go" ''
        package plg_authenticate_proxy_password

        import (
        "encoding/json"
        "html"
        "net/http"
        "net/url"
        "os"
        "strings"
        "time"

        . "github.com/mickael-kerjean/filestash/server/common"
        )

        func init() {
        Hooks.Register.AuthenticationMiddleware("proxy_password", ProxyPassword{})
        }

        type ProxyPassword struct{}

        type identityPayload struct {
        User     string `json:"user"`
        Email    string `json:"email"`
        Groups   string `json:"groups"`
        IssuedAt int64  `json:"issued_at"`
        }

        var sftpLoginUsersByEmail = map[string]string{
    ${sftpLoginUserEmailMapGo}
        }

        func sftpLoginUser(user string, email string) string {
        user = strings.TrimSpace(user)
        if username := sftpLoginUsersByEmail[strings.ToLower(user)]; username != "" {
            return username
        }
        if username := sftpLoginUsersByEmail[strings.ToLower(strings.TrimSpace(email))]; username != "" {
            return username
        }
        if name, _, ok := strings.Cut(user, "@"); ok {
            return name
        }
        return user
        }

        func (this ProxyPassword) Setup() Form {
        return Form{
            Elmnts: []FormElement{
                {Name: "type", Type: "hidden", Value: "proxy_password"},
                {Name: "user_header", Type: "text", Value: "X-Auth-Request-Preferred-Username"},
                {Name: "email_header", Type: "text", Value: "X-Auth-Request-Email"},
                {Name: "groups_header", Type: "text", Value: "X-Auth-Request-Groups"},
            },
        }
        }

        func headerFirst(req *http.Request, names ...string) string {
        for _, name := range names {
            if value := strings.TrimSpace(req.Header.Get(name)); value != "" {
                return value
            }
        }
        return ""
        }

        func (this ProxyPassword) EntryPoint(idpParams map[string]string, req *http.Request, res http.ResponseWriter) error {
        userHeader := idpParams["user_header"]
        if userHeader == "" {
            userHeader = "X-Auth-Request-Preferred-Username"
        }
        emailHeader := idpParams["email_header"]
        if emailHeader == "" {
            emailHeader = "X-Auth-Request-Email"
        }
        groupsHeader := idpParams["groups_header"]
        if groupsHeader == "" {
            groupsHeader = "X-Auth-Request-Groups"
        }

        user := headerFirst(req, userHeader, "X-Auth-Request-User", "X-Forwarded-Preferred-Username", "X-Forwarded-User")
        if user == "" {
            res.WriteHeader(http.StatusUnauthorized)
            res.Write([]byte(Page("Missing trusted proxy user header")))
            return nil
        }

        email := headerFirst(req, emailHeader, "X-Forwarded-Email")
        groups := headerFirst(req, groupsHeader, "X-Forwarded-Groups")
        payload := identityPayload{
            User:     user,
            Email:    email,
            Groups:   groups,
            IssuedAt: time.Now().Unix(),
        }
        raw, err := json.Marshal(payload)
        if err != nil {
            return err
        }
        token, err := EncryptString(SECRET_KEY_DERIVATE_FOR_USER, string(raw))
        if err != nil {
            return err
        }

        action := WithBase("/api/session/auth/?label=" + url.QueryEscape(req.URL.Query().Get("label")) + "&state=" + url.QueryEscape(req.URL.Query().Get("state")))

        res.Header().Set("Content-Type", "text/html; charset=utf-8")
        res.WriteHeader(http.StatusOK)
        res.Write([]byte(Page(
            "<style>" +
                ".filestash-proxy-login{min-height:100vh;display:grid;place-items:center;padding:24px;background:#f7f8fa;color:#17202a;font-family:Inter,system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;box-sizing:border-box}" +
                ".filestash-proxy-panel{width:min(100%,360px);display:grid;gap:16px;justify-items:center;text-align:center}" +
                ".filestash-proxy-logo{width:48px;height:48px;border-radius:8px;background:#1f6feb;color:#fff;display:grid;place-items:center;font-size:23px;font-weight:700;line-height:1}" +
                ".filestash-proxy-title{margin:0;font-size:20px;font-weight:650;line-height:1.25;letter-spacing:0}" +
                ".filestash-proxy-copy{margin:0;color:#5f6b7a;font-size:14px;line-height:1.5}" +
                ".filestash-proxy-spinner{width:28px;height:28px;border:3px solid #d8dee6;border-top-color:#1f6feb;border-radius:999px;animation:filestash-proxy-spin .8s linear infinite}" +
                ".filestash-proxy-button{min-height:40px;border:0;border-radius:6px;background:#1f6feb;color:#fff;padding:0 16px;font:inherit;font-weight:600;cursor:pointer}" +
                ".filestash-proxy-button:focus-visible{outline:3px solid rgba(31,111,235,.28);outline-offset:2px}" +
                "@keyframes filestash-proxy-spin{to{transform:rotate(360deg)}}" +
                "@media (prefers-color-scheme:dark){.filestash-proxy-login{background:#101418;color:#eef2f6}.filestash-proxy-copy{color:#a7b0bd}.filestash-proxy-spinner{border-color:#2b3540;border-top-color:#67a3ff}}" +
            "</style>" +
            "<main class=\"filestash-proxy-login\" aria-live=\"polite\">" +
                "<form id=\"filestash-proxy-password\" class=\"filestash-proxy-panel\" action=\"" + action + "\" method=\"post\">" +
                    "<div class=\"filestash-proxy-logo\" aria-hidden=\"true\">F</div>" +
                    "<h1 class=\"filestash-proxy-title\">Opening Files</h1>" +
                    "<p class=\"filestash-proxy-copy\">Your sign-in is complete. Connecting your file workspace now.</p>" +
                    "<div class=\"filestash-proxy-spinner\" aria-hidden=\"true\"></div>" +
                "<input type=\"hidden\" name=\"identity_token\" value=\"" + html.EscapeString(token) + "\" />" +
                    "<noscript><button class=\"filestash-proxy-button\" type=\"submit\">Continue to Files</button></noscript>" +
                "</form>" +
            "</main>" +
            "<script>document.getElementById('filestash-proxy-password').submit()</script>",
        )))
        return nil
        }

        func (this ProxyPassword) Callback(formData map[string]string, idpParams map[string]string, res http.ResponseWriter) (map[string]string, error) {
        token := strings.TrimSpace(formData["identity_token"])
        if token == "" {
            return nil, ErrAuthenticationFailed
        }
        decrypted, err := DecryptString(SECRET_KEY_DERIVATE_FOR_USER, token)
        if err != nil {
            return nil, ErrAuthenticationFailed
        }
        var payload identityPayload
        if err := json.Unmarshal([]byte(decrypted), &payload); err != nil {
            return nil, ErrAuthenticationFailed
        }
        if strings.TrimSpace(payload.User) == "" || payload.IssuedAt == 0 || time.Since(time.Unix(payload.IssuedAt, 0)) > 10*time.Minute {
            return nil, ErrAuthenticationFailed
        }
        privateKey, err := os.ReadFile("${sftpClientKeyFile}")
        if err != nil {
            return nil, ErrAuthenticationFailed
        }
        return map[string]string{
            "user":             payload.User,
            "sftp_user":        sftpLoginUser(payload.User, payload.Email),
            "email":            payload.Email,
            "groups":           payload.Groups,
            "sftp_private_key": string(privateKey),
        }, nil
        }
  '';
  filestashBackendWithProxyAuth = filestashPackages.backend.overrideAttrs (old: {
    passthru = old.passthru // {
      overrideModAttrs = lib.composeExtensions old.passthru.overrideModAttrs (_final: _prev: {
        env = (_prev.env or { }) // {
          GOFLAGS = "-mod=mod -trimpath";
        };
      });
    };

    postPatch = ''
        rm -rf vendor server/vendor

        chmod -R u+w server/plugin server/ctrl
        mkdir -p server/plugin/plg_authenticate_proxy_password
        install -m 0644 ${proxyPasswordPlugin} server/plugin/plg_authenticate_proxy_password/index.go

        substituteInPlace server/plugin/index.go \
                --replace-fail '_ "github.com/mickael-kerjean/filestash/server/plugin/plg_authenticate_passthrough"' '_ "github.com/mickael-kerjean/filestash/server/plugin/plg_authenticate_passthrough"
      _ "github.com/mickael-kerjean/filestash/server/plugin/plg_authenticate_proxy_password"'

              substituteInPlace server/ctrl/session.go \
                --replace-fail 'Log.Debug("session::authMiddleware '"'"'backend connection failed %+v - %s'"'"'", session, err.Error())' 'redactedSession := make(map[string]string, len(session))
          for k, v := range session {
              if strings.Contains(strings.ToLower(k), "password") {
                redactedSession[k] = "[redacted]"
              } else {
                redactedSession[k] = v
              }
            }
            Log.Debug("session::authMiddleware '"'"'backend connection failed %+v - %s'"'"'", redactedSession, err.Error())'

        substituteInPlace server/ctrl/session.go \
                --replace-fail $'cookie.SameSite = http.SameSiteStrictMode\n\tif Config.Get("features.protection.iframe").String() != "" {' $'cookie.SameSite = http.SameSiteStrictMode\n\tif Config.Get("general.force_ssl").Bool() {\n\t\tcookie.Secure = true\n\t}\n\tif Config.Get("features.protection.iframe").String() != "" {'

        substituteInPlace server/middleware/session.go \
                --replace-fail $'if ctx.Backend, err = _extractBackend(req, ctx); err != nil {\n\t\t\tif len(ctx.Session) == 0 {\n\t\t\t\tSendErrorResult(res, ErrNotAuthorized)\n\t\t\t\treturn\n\t\t\t}\n\t\t\tSendErrorResult(res, err)\n\t\t\treturn\n\t\t}' $'if ctx.Backend, err = _extractBackend(req, ctx); err != nil {\n\t\t\tif req.Method == http.MethodGet && req.URL.Path == WithBase("/api/session") {\n\t\t\t\tRecoverFromBadCookie(res)\n\t\t\t\tctx.Session = map[string]string{}\n\t\t\t\tctx.Backend = nil\n\t\t\t} else if len(ctx.Session) == 0 {\n\t\t\t\tSendErrorResult(res, ErrNotAuthorized)\n\t\t\t\treturn\n\t\t\t} else {\n\t\t\t\tSendErrorResult(res, err)\n\t\t\t\treturn\n\t\t\t}\n\t\t}'
    ''
    + (old.postPatch or "");
  });
  filestashPackage = pkgs.runCommand "filestash"
    {
      inherit (filestashBackendWithProxyAuth) meta;

      nativeBuildInputs = [ pkgs.makeBinaryWrapper ];

      pathConfig = "/proc/self/cwd/state/config.json";
      pathDb = "/proc/self/cwd/state/db";
      pathLog = "/proc/self/cwd/state/log";
      pathPlugins = "/proc/self/cwd/state/plugins";
      pathSearch = "/proc/self/cwd/state/search";
      pathCert = "/proc/self/cwd/state/certs";
      pathTmp = "/proc/self/cwd/cache";
      passthru = {
        proxyAuthPlugin = true;
        proxyPasswordAuthPlugin = true;
      };
    } ''
    mkdir --parents $out/bin
    ln --symbolic ${filestashBackendWithProxyAuth}/bin/filestash $out/bin/filestash
    wrapProgram $out/bin/filestash \
      --set-default FILESTASH_PATH $out/libexec/filestash

    mkdir --parents $out/libexec/filestash
    pushd $out/libexec/filestash

    mkdir --parents state/config
    ln --symbolic ${filestashPackages.frontend} public
    ln --symbolic "$pathConfig"  state/config/config.json
    ln --symbolic "$pathDb"      state/db
    ln --symbolic "$pathLog"     state/log
    ln --symbolic "$pathPlugins" state/plugins
    ln --symbolic "$pathSearch"  state/search
    ln --symbolic "$pathCert"    state/certs
    ln --symbolic "$pathTmp"     cache
  '';
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
          "files-sftp-sshd.service"
          "filestash-secret-materialize.service"
        ];
        wants = [
          "data-pool-layout.service"
          "files-sftp-sshd.service"
          "fileshare-user-root-sync.service"
          "filestash-secret-materialize.service"
          "network-online.target"
        ];
        after = [
          "data-pool-layout.service"
          "files-sftp-sshd.service"
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
