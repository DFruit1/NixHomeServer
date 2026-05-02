{ lib, pkgs, config, vars, copyparty, ... }:

let
  kanidmPort = 8443;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  userFilesGroup = "user-files";
  sharedFilesAdminGroup = "domain_admins";
  copypartyPort = 3923;
  runtimeConfigDir = "/var/lib/copyparty/runtime";
  runtimeConfigPath = "${runtimeConfigDir}/copyparty.conf";
  sharedFilesRoot = "${vars.sharedRoot}/files";
  sharedKiwixRoot = vars.kiwixLibraryRoot;
  mkVolumeStanza =
    {
      route,
      path,
      accs,
      chmodDir ? null,
      chmodFile ? null,
    }:
    let
      flags = [
        "fk: 4"
        "e2d: true"
      ]
      ++ lib.optional (chmodDir != null) "chmod_d: ${chmodDir}"
      ++ lib.optional (chmodFile != null) "chmod_f: ${chmodFile}"
      ++ [
        "unlistcr: true"
        "unlistcw: true"
      ];
    in
    ''
      [${route}]
      ${path}
      accs:
      ${lib.concatMapStringsSep "\n" (line: "  ${line}") accs}
      flags:
      ${lib.concatMapStringsSep "\n" (line: "  ${line}") flags}
    '';
  mkSharedVolume = route: path: mkVolumeStanza {
    inherit route path;
    accs = [
      "r: @shared-files-ro"
      "rwm: @shared-files-rw"
      "rwmda: @${sharedFilesAdminGroup}"
    ];
    chmodDir = "775";
    chmodFile = "664";
  };
  mkSharedAdminVolume = route: path: mkVolumeStanza {
    inherit route path;
    accs = [ "rwmda: @${sharedFilesAdminGroup}" ];
    chmodDir = "775";
    chmodFile = "664";
  };
  mkPersonalWritableVolume = route: path: mkVolumeStanza {
    inherit route path;
    accs = [ "rwmda: $username" ];
    chmodDir = "770";
    chmodFile = "660";
  };
  mkPersonalReadonlyVolume = route: path: mkVolumeStanza {
    inherit route path;
    accs = [ "r: $username" ];
  };
  sharedBookVolumes = lib.concatMapStringsSep "\n\n" (library:
    mkSharedVolume "/shared/${library.dir}" "${vars.sharedBooksRoot}/${library.dir}"
  ) vars.sharedKavitaLibraries;
  sharedBookAliasVolumes = lib.concatMapStringsSep "\n\n" (library:
    mkSharedVolume "/books/shared/${library.dir}" "${vars.sharedBooksRoot}/${library.dir}"
  ) vars.sharedKavitaLibraries;
  personalBookVolumes = lib.concatMapStringsSep "\n\n" (library:
    mkPersonalWritableVolume "/$username/${library.dir}" "${vars.usersRoot}/$username/books/${library.dir}"
  ) vars.personalKavitaLibraries;
  personalBookAliasVolumes = lib.concatMapStringsSep "\n\n" (library:
    mkPersonalWritableVolume "/books/$username/${library.dir}" "${vars.usersRoot}/$username/books/${library.dir}"
  ) vars.personalKavitaLibraries;
  sharedRuntimeVolumes = lib.concatStringsSep "\n\n" [
    (mkSharedVolume "/shared/files" sharedFilesRoot)
    (mkSharedVolume "/shared/audiobooks" vars.sharedAudiobooksRoot)
    sharedBookVolumes
    sharedBookAliasVolumes
    (mkSharedVolume "/shared/emails" vars.sharedEmailsRoot)
    (mkSharedVolume "/shared/videos" vars.sharedVideosRoot)
    (mkSharedAdminVolume "/shared/kiwix" sharedKiwixRoot)
  ];
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

    ${sharedRuntimeVolumes}
  '';
  appendPersonalVolumes = ''
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

${mkPersonalWritableVolume "/$username/files" "${vars.usersRoot}/$username/files"}

${mkPersonalWritableVolume "/$username/audiobooks" "${vars.usersRoot}/$username/audiobooks"}

${personalBookVolumes}

${personalBookAliasVolumes}

${mkPersonalReadonlyVolume "/$username/emails" "${vars.usersRoot}/$username/emails"}
EOF
        done
  '';
  buildRuntimeConfig = ''
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
      ${sharedRuntimeVolumes}
    '';
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
    description = "Build Copyparty runtime config with live user-files membership";
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
    path = [
      pkgs.coreutils
      pkgs.kanidm_1_9
      pkgs.jq
    ];
    script = buildRuntimeConfig;
  };
}
