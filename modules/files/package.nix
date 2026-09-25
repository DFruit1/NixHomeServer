{ lib, pkgs, vars, sftpClientKeyFile, sftpLoginUserEmailMapGo }:

let
  transfersHost = "transfers.${vars.domain}";

  # Filestash is not a flake and its packaging flake (dermetfan/filestash.nix)
  # still targets the pre-`server/pkg` layout, so this module owns the package.
  # Bump `rev` and `hash` together:
  #   nix flake prefetch github:mickael-kerjean/filestash/<rev> --json
  source = pkgs.fetchFromGitHub {
    owner = "mickael-kerjean";
    repo = "filestash";
    rev = "426bb93b2b93f68d8abf378302228ca5e7e51898";
    hash = "sha256-4QBmuBkOg1+ItPbEV4mLVa/2vz6XHY6tsd1yQghhYlI=";
  };

  # The console plugins embed xterm assets that upstream's `go generate`
  # directives download from cdnjs. Pin them instead so the build stays offline;
  # xterm.js is concatenated with the fit addon exactly like the generator does.
  xterm = {
    js = pkgs.fetchurl {
      url = "https://cdnjs.cloudflare.com/ajax/libs/xterm/3.12.2/xterm.js";
      hash = "sha256-kmKnFnK+yIhGOrAALLJbBXQml6qPraKPLHz41N8KFvM=";
    };
    fitJs = pkgs.fetchurl {
      url = "https://cdnjs.cloudflare.com/ajax/libs/xterm/3.12.2/addons/fit/fit.js";
      hash = "sha256-NJ84uZRKbjotj1hgHNwdEuqkJXgrcaycw7RMRHwZ4lc=";
    };
    css = pkgs.fetchurl {
      url = "https://cdnjs.cloudflare.com/ajax/libs/xterm/3.12.2/xterm.css";
      hash = "sha256-4NJwjyaTn7Tik3/1e0Ueyr512PH3kx/o7oyEDM2Xo7E=";
    };
  };

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
        "github.com/mickael-kerjean/filestash/server/pkg/env"
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
        token, err := EncryptString(env.SECRET_KEY_DERIVATE_FOR_USER, string(raw))
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
        decrypted, err := DecryptString(env.SECRET_KEY_DERIVATE_FOR_USER, token)
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

  officePluginAssets = {
    sofficeJs = pkgs.fetchurl {
      url = "https://cdn.zetaoffice.net/zetaoffice_latest/soffice.js";
      hash = "sha256-UUPlNU9HC4f4a6JyvP74V70T5vB7WWZuSKfMuJZDzXc=";
    };
    sofficeWasm = pkgs.fetchurl {
      url = "https://cdn.zetaoffice.net/zetaoffice_latest/soffice.wasm";
      hash = "sha256-oRgIqro8mkQSqGW95kUkf9nQsmK1uqBoCp/O0pqGVuQ=";
    };
    sofficeMetadata = pkgs.fetchurl {
      url = "https://cdn.zetaoffice.net/zetaoffice_latest/soffice.data.js.metadata";
      hash = "sha256-XZ2QnQubOEQ8DxlwQDLQ/BLWVPbJwkwsOyN3OcSEiuM=";
    };
    sofficeData = pkgs.fetchurl {
      url = "https://cdn.zetaoffice.net/zetaoffice_latest/soffice.data";
      hash = "sha256-nTwc88kEzlcJBQUrpoRPM4P96TrRJntlo65LI22y/QU=";
    };
    zetaJs = pkgs.fetchurl {
      url = "https://zetaoffice.net/demos/standalone/assets/vendor/zetajs/zeta.js";
      hash = "sha256-tw7nAikIgixRJTW79DxORMKXrMNk51Qqu6DTBx9fm/0=";
    };
  };

  officePluginArchive = pkgs.runCommand "filestash-application-office.zip"
    {
      nativeBuildInputs = [ pkgs.zip pkgs.jq ];
    } ''
    cp -r ${source}/server/plugin/plg_application_office plugin
    chmod -R u+w plugin
    mkdir -p plugin/lib/lowa
    cp ${officePluginAssets.sofficeJs} plugin/lib/lowa/soffice.js
    cp ${officePluginAssets.sofficeWasm} plugin/lib/lowa/soffice.wasm.br
    cp ${officePluginAssets.sofficeMetadata} plugin/lib/lowa/soffice.data.js.metadata
    cp ${officePluginAssets.sofficeData} plugin/lib/lowa/soffice.data.br
    cp ${officePluginAssets.zetaJs} plugin/lib/lowa/zeta.js
    # Drop the upstream wasm middleware module: this revision's extension
    # discovery has no case for its declared type and aborts on the whole
    # archive. The in-tree Go middleware already sets the same COOP/COEP headers.
    jq 'del(.modules[] | select(.type == "middleware"))' \
      plugin/manifest.json > plugin/manifest.json.new
    mv plugin/manifest.json.new plugin/manifest.json
    find plugin -exec touch -h -d @1 {} +
    cd plugin
    zip -X -q -r "$out" . -x "lib/vendor/*"
  '';

  backend = pkgs.buildGoModule {
    pname = "filestash-backend";
    version = source.shortRev or "unstable";

    src = source;

    meta = {
      description = "A modern web client for SFTP, S3, FTP, WebDAV, Git, Minio, LDAP, CalDAV, CardDAV, Mysql, Backblaze";
      homepage = "https://github.com/mickael-kerjean/filestash";
      license = lib.licenses.agpl3Only;
      mainProgram = "filestash";
      platforms = lib.platforms.linux;
    };

    vendorHash = "sha256-EMBEVNnk683WX8Ab6Lz8358TmUvYiJfO76LLApYxKsU=";

    # The module-vendoring derivation inherits GOFLAGS=-mod=vendor, which
    # `go mod vendor` rejects; allow module mode while it resolves the graph.
    overrideModAttrs = _finalAttrs: prevAttrs: {
      env = (prevAttrs.env or { }) // {
        GOFLAGS = "-mod=mod -trimpath";
      };
    };

    subPackages = [ "cmd" ];

    # Image/thumbnail plugins are cgo extensions.
    env.CGO_ENABLED = 1;

    ldflags = [
      "-X github.com/mickael-kerjean/filestash/server/pkg/env.BUILD_REF=${source.rev}"
      "-X github.com/mickael-kerjean/filestash/server/pkg/env.BUILD_DATE=${source.rev}"
    ];

    tags = [ "fts5" ];

    excludedPackages = [ "server/generator" ];

    buildInputs = with pkgs; [
      vips
      brotli
      ffmpeg
      libjpeg
      libpng
      libwebp
      libraw
      giflib
      libheif
      stb
    ];

    nativeBuildInputs = with pkgs; [
      pkg-config
      makeBinaryWrapper
    ];

    patches = [
      ./patches/filespage-filetype-glyphs.patch
      ./patches/share-links-transfers.patch
      ./patches/filestash-plugin-registration.patch
      ./patches/filestash-readonly-shares.patch
      ./patches/filestash-cookie-secure.patch
      ./patches/filestash-session-recovery.patch
      ./patches/filestash-image-psd-stb.patch
    ];
    patchFlags = "--strip=0";

    postPatch = ''
      # xterm assets for the console plugins (upstream downloads them at build
      # time; keep the build offline). The generator appends fit.js to xterm.js.
      install -m 0644 ${xterm.js} server/plugin/plg_handler_console/src/xterm.js
      cat ${xterm.fitJs} >> server/plugin/plg_handler_console/src/xterm.js
      install -m 0644 ${xterm.css} server/plugin/plg_handler_console/src/xterm.css
      install -m 0644 ${xterm.js} server/plugin/plg_widget_console/assets/vendor/xterm.js
      cat ${xterm.fitJs} >> server/plugin/plg_widget_console/assets/vendor/xterm.js
      install -m 0644 ${xterm.css} server/plugin/plg_widget_console/assets/vendor/xterm.css

      # cgo links the static archive names vendored in image_c; nixpkgs ships
      # shared libraries instead.
      sed -i -E 's/-l:lib([A-Za-z0-9_+]+)\.a/-l\1/g' server/plugin/plg_image_c/*.go

      # The generated plugin is added to the plugin index by
      # filestash-plugin-registration.patch.
      mkdir -p server/plugin/plg_authenticate_proxy_password
      install -m 0644 ${proxyPasswordPlugin} server/plugin/plg_authenticate_proxy_password/index.go

      # Share links copied from the authenticated UI must point at the
      # unauthenticated transfers host. The embedded frontend builds them from
      # the current origin; bake in the transfers origin.
      substituteInPlace public/assets/pages/filespage/modal_share.js \
        --replace-fail 'TRANSFERS_HOST_PLACEHOLDER' 'https://${transfersHost}'
      test "$(grep -cF 'https://${transfersHost}' public/assets/pages/filespage/modal_share.js)" -eq 4
    '';

    preBuild = ''
      # `*_generated.go` is gitignored upstream. Generate the mime table locally
      # and pin the build metadata (the env generator shells out to git).
      cat > server/pkg/env/constants_generated.go <<EOF
      package env

      var (
      	BUILD_REF  = "${source.rev}"
      	BUILD_DATE = "${source.rev}"
      )
      EOF
      go generate ./server/pkg/mime
    '';

    postInstall = "mv $out/bin/cmd $out/bin/filestash";

    preFixup = ''
      wrapProgram $out/bin/filestash \
        --suffix PATH : ${lib.makeBinPath [ pkgs.ffmpeg ]}
    '';

    doCheck = false;
  };

  default = pkgs.runCommand "filestash"
    {
      inherit (backend) meta;

      nativeBuildInputs = [ pkgs.makeBinaryWrapper ];

      pathConfig = "/proc/self/cwd/state/config.json";
      pathDb = "/proc/self/cwd/state/db";
      pathLog = "/proc/self/cwd/state/log";
      pathPlugins = "/proc/self/cwd/state/plugins";
      pathSearch = "/proc/self/cwd/state/search";
      pathCert = "/proc/self/cwd/state/certs";
      pathTmp = "/proc/self/cwd/cache";
      passthru = {
        officePlugin = true;
        proxyAuthPlugin = true;
        proxyPasswordAuthPlugin = true;
      };
    } ''
    mkdir --parents $out/bin
    ln --symbolic ${backend}/bin/filestash $out/bin/filestash
    wrapProgram $out/bin/filestash \
      --set-default FILESTASH_PATH $out/libexec/filestash

    mkdir --parents $out/libexec/filestash
    pushd $out/libexec/filestash

    mkdir --parents state/config
    ln --symbolic "$pathConfig"  state/config/config.json
    ln --symbolic "$pathDb"      state/db
    ln --symbolic "$pathLog"     state/log
    ln --symbolic "$pathPlugins" state/plugins
    ln --symbolic "$pathSearch"  state/search
    ln --symbolic "$pathCert"    state/certs
    ln --symbolic "$pathTmp"     cache
  '';
in
{
  inherit backend default officePluginArchive;
}
