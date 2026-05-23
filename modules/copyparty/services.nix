{ lib, config, vars, copyparty, ... }:

let
  enabled = config.nixhomeserver.apps.copyparty.enable;
  copypartyPort = vars.networking.ports.copyparty;
  loopback = vars.networking.loopbackIPv4;
in

{
  imports = [
    copyparty.nixosModules.default
    ./oauth2-proxy.nix
    ./upload-processing.nix
  ];

  config = lib.mkIf enabled {
    nixpkgs.overlays = [ copyparty.overlays.default ];

    services.copyparty = {
      enable = true;
      openFilesLimit = 8192;
      settings = {
        i = loopback;
        p = copypartyPort;
        auth-ord = "idp";
        idp-h-usr = "x-forwarded-preferred-username";
        idp-h-grp = "x-forwarded-groups";
        idp-store = 3;
        idp-login = "/oauth2/start?rd={dst}";
        idp-login-t = "Continue with Kanidm";
        # This clears the proxy session and immediately starts the login flow again.
        idp-logout = "/oauth2/sign_out?rd=/oauth2/start?rd=%2F";
        no-bauth = true;
        rproxy = 1;
        s-tbody = 0;
        snap-drop = 10080;
        u2j = 1;
        u2sz = "1,8,16";
        xff-hdr = "x-forwarded-for";
        xff-src = vars.networking.loopbackProxyCidr;
        no-reload = true;
      };
      volumes."/\${u}" = {
        path = "${vars.uploadSecurity.stagingRoot}/\${u}";
        access.w = "\${u}";
        flags = {
          fk = 4;
          e2d = true;
          chmod_d = 730;
          chmod_f = 660;
          xau = "f,j,/run/current-system/sw/bin/upload-processor-enqueue";
        };
      };
    };

    systemd.services.copyparty = {
      wants = [
        "fileshare-user-root-sync.service"
        "upload-processor-runtime-layout.service"
      ];
      after = [
        "fileshare-user-root-sync.service"
        "upload-processor-runtime-layout.service"
      ];
      preStart = lib.mkAfter ''
        ${lib.getExe config.services.copyparty.package} -c /run/copyparty/copyparty.conf --exit cfg
      '';
      serviceConfig.BindPaths = lib.mkAfter [ vars.uploadSecurity.stagingRoot ];
      serviceConfig.ReadWritePaths = [
        vars.uploadSecurity.stagingRoot
      ];
      serviceConfig.SupplementaryGroups = [
        "upload-staging"
      ];
    };
  };
}
