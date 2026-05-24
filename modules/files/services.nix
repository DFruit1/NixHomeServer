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
  adminPasswordHashFile = "${managedDir}/admin-password.bcrypt";
  oauth2ClientSecretFile = "${secretRuntimeDir}/oauth2-client-secret";
  oauth2CookieSecretFile = "${secretRuntimeDir}/oauth2-cookie-secret";
  webAccessGroup = vars.fileAccess.webAccessGroup or "user-files";
  proxyUserHeader = "X-Auth-Request-Preferred-Username";
  proxyEmailHeader = "X-Auth-Request-Email";
  proxyGroupsHeader = "X-Auth-Request-Groups";
  filesSftpPort = vars.networking.ports.filesSftp;
  filestashPackages = filestashNix.packages.${pkgs.stdenv.hostPlatform.system};
  proxyPasswordPlugin = pkgs.writeText "plg_authenticate_proxy_password.go" ''
    package plg_authenticate_proxy_password

    import (
    	"encoding/json"
    	"html"
    	"net/http"
    	"net/url"
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
    		"<form action=\"" + action + "\" method=\"post\">" +
    			"<input type=\"hidden\" name=\"identity_token\" value=\"" + html.EscapeString(token) + "\" />" +
    			"<label>Signed in as " + html.EscapeString(user) + "</label>" +
    			"<input autofocus required type=\"password\" name=\"password\" autocomplete=\"current-password\" placeholder=\"Password\" />" +
    			"<button type=\"submit\">Connect</button>" +
    		"</form>",
    	)))
    	return nil
    }

    func (this ProxyPassword) Callback(formData map[string]string, idpParams map[string]string, res http.ResponseWriter) (map[string]string, error) {
    	token := strings.TrimSpace(formData["identity_token"])
    	password := formData["password"]
    	if token == "" || password == "" {
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
    	return map[string]string{
    		"user":     payload.User,
    		"email":    payload.Email,
    		"groups":   payload.Groups,
    		"password": password,
    	}, nil
    }
  '';
  filestashBackendWithProxyAuth = filestashPackages.backend.overrideAttrs (old: {
    postPatch = ''
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
      		Log.Debug("session::authMiddleware '"'"'backend connection failed %+v - %s'"'"'", redactedSession, err.Error())' \
              --replace-fail 'cookie.SameSite = http.SameSiteStrictMode
      	if Config.Get("features.protection.iframe").String() != "" {' 'cookie.SameSite = http.SameSiteStrictMode
      	if Config.Get("general.force_ssl").Bool() {
      		cookie.Secure = true
      	}
      	if Config.Get("features.protection.iframe").String() != "" {'
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
      username = "{{ .user }}";
      password = "{{ .password }}";
      path = "/";
    };
  };
  sftpBackendConnections = [
    {
      type = "sftp";
      label = "Files";
      hostname = loopback;
      port = toString filesSftpPort;
      path = "/";
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
      allowedGroups = [ webAccessGroup ];
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
