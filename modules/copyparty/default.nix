{ lib, pkgs, config, vars, copyparty, ... }:

let
  sharedFilesAdminGroup = "domain_admins";
  copypartyPort = 3923;
  runtimeConfigDir = "/var/lib/copyparty/runtime";
  runtimeConfigPath = "${runtimeConfigDir}/copyparty.conf";
  uploaderVolumeConfig = ''
    [/upload/''${u}]
    ${vars.usersRoot}/''${u}/uploads
    accs:
      rwmda: ''${u}, @${sharedFilesAdminGroup}
    flags:
      fk: 4
      e2d: true
      chmod_d: 2770
      chmod_f: 660
  '';
  buildRuntimeConfig = ''
    set -euo pipefail

    install -d -m 0700 -o copyparty -g copyparty ${runtimeConfigDir}
    cat >${runtimeConfigPath} <<'EOF'
    [global]
    auth-ord: idp
    i: 127.0.0.1
    idp-h-grp: x-forwarded-groups
    idp-h-usr: x-forwarded-preferred-username
    idp-login: /oauth2/start?rd={dst}
    idp-login-t: Continue with Kanidm
    idp-logout: /oauth2/sign_out?rd=/oauth2/start?rd=%2F
    idp-store: 3
    no-bauth
    no-reload
    p: ${toString copypartyPort}
    rproxy: 1
    xff-hdr: x-forwarded-for
    xff-src: 127.0.0.1/32

    [accounts]

    [groups]

    ${uploaderVolumeConfig}
    EOF
    chmod 0600 ${runtimeConfigPath}
    chown copyparty:copyparty ${runtimeConfigPath}
    ${pkgs.copyparty}/bin/copyparty -c ${runtimeConfigPath} --exit cfg
  '';
in

{
  imports = [ copyparty.nixosModules.default ];

  nixpkgs.overlays = [ copyparty.overlays.default ];

  services.copyparty = {
    enable = true;
    openFilesLimit = 8192;
    settings = {
      i = "127.0.0.1";
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
      xff-hdr = "x-forwarded-for";
      xff-src = "127.0.0.1/32";
      no-reload = true;
    };
    volumes = { };
    globalExtraConfig = uploaderVolumeConfig;
  };

  services.kiwixServe.extraUploadUsers = lib.optionals config.services.kiwixServe.enable [ "copyparty" ];

  users.users.copyparty.extraGroups = lib.mkAfter [
    "users"
    "mail-archive-ui"
  ];

  systemd.services.copyparty = {
    wants = lib.optionals config.services.kiwixServe.enable [ "kiwix-library-sync.service" ] ++ [
      "copyparty-runtime-config-sync.service"
      "fileshare-user-root-sync.service"
    ];
    after = lib.optionals config.services.kiwixServe.enable [ "kiwix-library-sync.service" ] ++ [
      "copyparty-runtime-config-sync.service"
      "fileshare-user-root-sync.service"
    ];
    serviceConfig.BindPaths = lib.mkAfter (
      [
        vars.usersRoot
        vars.sharedRoot
      ]
      ++ lib.optionals config.services.kiwixServe.enable [ vars.kiwixLibraryRoot ]
    );
    serviceConfig.ExecStart = lib.mkForce "${pkgs.copyparty}/bin/copyparty -c ${runtimeConfigPath}";
    serviceConfig.ExecStartPre = lib.mkForce [ ];
  };

  systemd.services.copyparty-runtime-config-sync = {
    description = "Build Copyparty runtime config";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "fileshare-user-root-sync.service"
      "local-fs.target"
    ];
    after = [
      "fileshare-user-root-sync.service"
      "local-fs.target"
    ];
    before = [ "copyparty.service" ];
    serviceConfig = {
      Type = "oneshot";
    };
    path = [ pkgs.coreutils ];
    script = buildRuntimeConfig;
  };
}
