{ lib, vars, copyparty, ... }:

let
  copypartyPort = 3923;
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
      shr = "/shares";
      "shr-who" = "auth";
      "shr-site" = "https://${vars.filesDomain}";
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
    globalExtraConfig = ''
      [/''${u}]
      ${vars.usersWorkspaceRoot}/''${u}
      accs:
        rwmda: ''${u}
      flags:
        fk: 4
        e2d: true
        chmod_d: 770
        chmod_f: 660
        unlistcr: true
        unlistcw: true

      [/''${u}/emails]
      ${vars.usersWorkspaceRoot}/''${u}/emails
      accs:
        r: ''${u}
      flags:
        fk: 4
        e2d: true
        unlistcr: true
        unlistcw: true

      [/shared/documents]
      ${vars.mediaRoot}/documents/archive
      accs:
        r: @acct
      flags:
        fk: 4
        e2d: true
        unlistcr: true
        unlistcw: true

      [/shared/emails]
      ${vars.sharedEmailsRoot}
      accs:
        r: @acct
      flags:
        fk: 4
        e2d: true
        unlistcr: true
        unlistcw: true

      [/shared/videos]
      ${vars.sharedVideosRoot}
      accs:
        rw: @acct
        rwmda: ${vars.kanidmAdminUser}
      flags:
        fk: 4
        e2d: true
        chmod_d: 775
        chmod_f: 664
        unlistcr: true
        unlistcw: true

      [/shared]
      ${vars.sharedPublicRoot}
      accs:
        rwmda: @acct
      flags:
        fk: 4
        e2d: true
        chmod_d: 775
        chmod_f: 664
        unlistcr: true
        unlistcw: true
    '';
  };

  users.users.copyparty.extraGroups = lib.mkAfter [
    "users"
    "paperless"
    "mail-archive-ui"
  ];

  systemd.services.copyparty = {
    wants = [
      "fileshare-workspace-sync.service"
      "paperless-storage-layout-v1.service"
    ];
    after = [
      "fileshare-workspace-sync.service"
      "paperless-storage-layout-v1.service"
    ];
    serviceConfig.BindPaths = lib.mkAfter [
      vars.usersWorkspaceRoot
      vars.sharedPublicRoot
      "${vars.mediaRoot}/documents/archive"
    ];
  };
}
