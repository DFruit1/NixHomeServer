{ lib, pkgs, config, vars, copyparty, ... }:

let
  kanidmPort = 8443;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  userFilesGroup = "user-files";
  copypartyPort = 3923;
  runtimeConfigDir = "/var/lib/copyparty/runtime";
  runtimeConfigPath = "${runtimeConfigDir}/copyparty.conf";
  sharedFilesRoot = "${vars.sharedRoot}/files";
  staticRuntimeConfig = pkgs.writeText "copyparty-runtime.conf" ''
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
    shr: /shares
    shr-site: https://${vars.filesDomain}
    shr-who: auth
    xff-hdr: x-forwarded-for
    xff-src: 127.0.0.1/32

    [accounts]

    [groups]

    [/shared/files]
    ${sharedFilesRoot}
    accs:
      r: @shared-files-ro, @shared-files-rw
    flags:
      fk: 4
      e2d: true
      chmod_d: 775
      chmod_f: 664
      unlistcr: true
      unlistcw: true

    [/shared/audiobooks]
    ${vars.sharedAudiobooksRoot}
    accs:
      r: @shared-files-ro, @shared-files-rw
    flags:
      fk: 4
      e2d: true
      chmod_d: 775
      chmod_f: 664
      unlistcr: true
      unlistcw: true

    [/shared/books]
    ${vars.sharedBooksRoot}
    accs:
      r: @shared-files-ro, @shared-files-rw
    flags:
      fk: 4
      e2d: true
      chmod_d: 775
      chmod_f: 664
      unlistcr: true
      unlistcw: true

    [/shared/emails]
    ${vars.sharedEmailsRoot}
    accs:
      r: @shared-files-ro, @shared-files-rw
    flags:
      fk: 4
      e2d: true
      chmod_d: 775
      chmod_f: 664
      unlistcr: true
      unlistcw: true

    [/shared/videos]
    ${vars.sharedVideosRoot}
    accs:
      r: @shared-files-ro, @shared-files-rw
    flags:
      fk: 4
      e2d: true
      chmod_d: 775
      chmod_f: 664
      unlistcr: true
      unlistcw: true
  '';
  appendPersonalVolumes = pkgs.writeShellScript "append-copyparty-personal-volumes" ''
    set -euo pipefail

    runtime_conf="${runtimeConfigPath}"
    export HOME="$(${pkgs.coreutils}/bin/mktemp -d)"
    trap '${pkgs.coreutils}/bin/rm -rf "$HOME"' EXIT
    export KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmAdminPass.path})"

    ${pkgs.kanidm_1_9}/bin/kanidm login \
      -H ${kanidmCliUrl} \
      -D idm_admin >/dev/null

    ${pkgs.kanidm_1_9}/bin/kanidm group get \
      ${lib.escapeShellArg userFilesGroup} \
      -H ${kanidmCliUrl} \
      -D idm_admin \
      -o json \
      | ${pkgs.jq}/bin/jq -r '.attrs.member[]? | split("@")[0]' \
      | ${pkgs.coreutils}/bin/sort -u \
      | while IFS= read -r username; do
          [[ -n "$username" ]] || continue

          ${pkgs.coreutils}/bin/cat >>"$runtime_conf" <<EOF

[/$username/files]
${vars.usersRoot}/$username/files
accs:
  rwmda: $username
flags:
  fk: 4
  e2d: true
  chmod_d: 770
  chmod_f: 660
  unlistcr: true
  unlistcw: true

[/$username/audiobooks]
${vars.usersRoot}/$username/audiobooks
accs:
  rwmda: $username
flags:
  fk: 4
  e2d: true
  chmod_d: 770
  chmod_f: 660
  unlistcr: true
  unlistcw: true

[/$username/books]
${vars.usersRoot}/$username/books
accs:
  rwmda: $username
flags:
  fk: 4
  e2d: true
  chmod_d: 770
  chmod_f: 660
  unlistcr: true
  unlistcw: true

[/$username/emails]
${vars.usersRoot}/$username/emails
accs:
  r: $username
flags:
  fk: 4
  e2d: true
  unlistcr: true
  unlistcw: true
EOF
        done
  '';
  buildRuntimeConfig = pkgs.writeShellScript "build-copyparty-runtime-config" ''
    set -euo pipefail

    install -d -m 0700 -o copyparty -g copyparty ${runtimeConfigDir}
    install -m 0600 ${staticRuntimeConfig} ${runtimeConfigPath}
    ${appendPersonalVolumes}
    chown copyparty:copyparty ${runtimeConfigPath}
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
      [/shared/files]
      ${sharedFilesRoot}
      accs:
        r: @shared-files-ro, @shared-files-rw
      flags:
        fk: 4
        e2d: true
        chmod_d: 775
        chmod_f: 664
        unlistcr: true
        unlistcw: true

      [/shared/audiobooks]
      ${vars.sharedAudiobooksRoot}
      accs:
        r: @shared-files-ro, @shared-files-rw
      flags:
        fk: 4
        e2d: true
        chmod_d: 775
        chmod_f: 664
        unlistcr: true
        unlistcw: true

      [/shared/books]
      ${vars.sharedBooksRoot}
      accs:
        r: @shared-files-ro, @shared-files-rw
      flags:
        fk: 4
        e2d: true
        chmod_d: 775
        chmod_f: 664
        unlistcr: true
        unlistcw: true

      [/shared/emails]
      ${vars.sharedEmailsRoot}
      accs:
        r: @shared-files-ro, @shared-files-rw
      flags:
        fk: 4
        e2d: true
        chmod_d: 775
        chmod_f: 664
        unlistcr: true
        unlistcw: true

      [/shared/videos]
      ${vars.sharedVideosRoot}
      accs:
        r: @shared-files-ro, @shared-files-rw
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
    "mail-archive-ui"
  ];

  systemd.services.copyparty = {
    wants = [
      "copyparty-runtime-config-sync.service"
      "fileshare-user-root-sync.service"
      "kanidm-files-posix-groups.service"
    ];
    after = [
      "copyparty-runtime-config-sync.service"
      "fileshare-user-root-sync.service"
      "kanidm-files-posix-groups.service"
    ];
    serviceConfig.BindPaths = lib.mkAfter [
      vars.usersRoot
      vars.sharedRoot
    ];
    serviceConfig.ExecStart = lib.mkForce "${pkgs.copyparty}/bin/copyparty -c ${runtimeConfigPath}";
    serviceConfig.ExecStartPre = lib.mkForce [ ];
  };

  systemd.services.copyparty-runtime-config-sync = {
    description = "Build Copyparty runtime config with live user-files membership";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "fileshare-user-root-sync.service"
      "kanidm-files-posix-groups.service"
      "local-fs.target"
    ];
    after = [
      "fileshare-user-root-sync.service"
      "kanidm-files-posix-groups.service"
      "local-fs.target"
    ];
    before = [ "copyparty.service" ];
    serviceConfig = {
      Type = "oneshot";
    };
    path = [
      pkgs.coreutils
      pkgs.kanidm_1_9
      pkgs.jq
    ];
    script = ''
      ${buildRuntimeConfig}
    '';
  };
}
