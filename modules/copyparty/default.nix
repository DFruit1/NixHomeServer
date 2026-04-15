{ lib, config, vars, copyparty, ... }:

{
  imports = [ copyparty.nixosModules.default ];

  nixpkgs.overlays = [ copyparty.overlays.default ];

  services.copyparty = {
    enable = true;
    openFilesLimit = 8192;
    settings = {
      i = "127.0.0.1";
      p = vars.copypartyPort;
      auth-ord = "idp";
      idp-h-usr = "x-forwarded-preferred-username";
      idp-h-grp = "x-forwarded-groups";
      idp-store = 3;
      idp-login = "/oauth2/start?rd={dst}";
      idp-login-t = "Continue with Kanidm";
      idp-logout = "/oauth2/sign_out?rd=/";
      no-bauth = true;
      rproxy = 1;
      xff-hdr = "x-forwarded-for";
      xff-src = "127.0.0.1/32";
      no-reload = true;
    };
    volumes = { };
    globalExtraConfig = ''

      [/me/''${u}]
      ${vars.usersWorkspaceRoot}/''${u}/files
      accs:
        rwmda: ''${u}
      flags:
        fk: 4
        e2d: true
        chmod_d: 770
        chmod_f: 660

      [/shared/exchange]
      ${vars.sharedExchangeRoot}
      accs:
        rwmda: *
      flags:
        fk: 4
        e2d: true
        chmod_d: 775
        chmod_f: 664

      [/shared/public]
      ${vars.sharedPublicRoot}
      accs:
        rwmda: *
      flags:
        fk: 4
        e2d: true
        chmod_d: 775
        chmod_f: 664

      [/incoming/photos]
      ${vars.photosUploadRoot}
      accs:
        rwmda: *
      flags:
        fk: 4
        e2d: true
        chmod_d: 2770
        chmod_f: 660

      [/incoming/documents]
      ${vars.documentsUploadRoot}
      accs:
        rwmda: *
      flags:
        fk: 4
        e2d: true
        chmod_d: 2770
        chmod_f: 660
    '';
  };

  users.users.copyparty.extraGroups = [ "users" "immich" "paperless" ];

  systemd.services.copyparty.serviceConfig.BindPaths = lib.mkAfter [
    vars.usersWorkspaceRoot
    vars.sharedExchangeRoot
    vars.sharedPublicRoot
    vars.photosUploadRoot
    vars.documentsUploadRoot
  ];
}
