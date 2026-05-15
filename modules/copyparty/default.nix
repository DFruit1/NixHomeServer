{ lib, config, vars, copyparty, ... }:

let
  copypartyPort = vars.networking.ports.copyparty;
  loopback = vars.networking.loopbackIPv4;
in

{
  imports = [ copyparty.nixosModules.default ];

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
      path = "${vars.usersRoot}/\${u}/uploads";
      access.rwmd = "\${u}";
      flags = {
        fk = 4;
        e2d = true;
        chmod_d = 770;
        chmod_f = 660;
      };
    };
  };

  users.users.copyparty.extraGroups = lib.mkAfter [
    "users"
  ];

  systemd.services.copyparty = {
    wants = [
      "fileshare-user-root-sync.service"
    ];
    after = [
      "fileshare-user-root-sync.service"
    ];
    preStart = lib.mkAfter ''
      ${lib.getExe config.services.copyparty.package} -c /run/copyparty/copyparty.conf --exit cfg
    '';
    serviceConfig.BindPaths = lib.mkAfter [ vars.usersRoot ];
    serviceConfig.SupplementaryGroups = [
      "users"
    ];
  };
}
