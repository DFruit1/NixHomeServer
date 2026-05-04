{ lib, pkgs, vars, ... }:

let
  zfsBin = "${pkgs.zfs}/bin/zfs";
  canonicalUsersDataset = "${vars.zfsDataPool.name}/users";
  canonicalSharedDataset = "${vars.zfsDataPool.name}/shared";
  genericSharedContentDirs = map (name: "${vars.sharedRoot}/${name}") (
    builtins.filter (name: name != "emails") vars.sharedContentSubdirs
  );
  sharedBooksDirs = map (name: "${vars.sharedBooksRoot}/${name}") vars.sharedBooksSubdirs;
  sharedVideoDirs = map (name: "${vars.sharedVideosRoot}/${name}") vars.sharedVideoSubdirs;
  sharedKavitaDirs = map (library: "${vars.sharedBooksRoot}/${library.dir}") vars.sharedKavitaLibraries;
  sharedJellyfinDirs = map (library: "${vars.sharedVideosRoot}/${library.dir}") vars.sharedJellyfinLibraries;
  managedUnits = [
    "audiobookshelf.service"
    "copyparty.service"
    "fileshare-user-root-sync.service"
    "jellyfin.service"
    "kavita.service"
    "mail-archive-sync.service"
    "mail-archive-ui.service"
    "paperless-consumer.service"
    "paperless-scheduler.service"
    "paperless-task-queue.service"
    "paperless-web.service"
  ];

  mkDirCmd =
    { path
    , mode
    , user
    , group
    ,
    }:
    "${pkgs.coreutils}/bin/install -d -m ${mode} -o ${user} -g ${group} '${path}'";

  mkImmichSentinelCmd = path: ''
    ${pkgs.coreutils}/bin/touch '${path}'
    ${pkgs.coreutils}/bin/chown immich:immich '${path}'
    ${pkgs.coreutils}/bin/chmod 0640 '${path}'
  '';

  zfsContentDirs = [
    {
      path = vars.dataRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = vars.paperlessRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = vars.immichRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = vars.usersRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = vars.sharedRoot;
      mode = "2775";
      user = "root";
      group = "users";
    }
    {
      path = vars.immichManagedRoot;
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = "${vars.immichManagedRoot}/backups";
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = "${vars.immichManagedRoot}/encoded-video";
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = "${vars.immichManagedRoot}/library";
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = "${vars.immichManagedRoot}/profile";
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = "${vars.immichManagedRoot}/thumbs";
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = "${vars.immichManagedRoot}/upload";
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = vars.immichExternalRoot;
      mode = "2770";
      user = "root";
      group = "immich";
    }
    {
      path = vars.paperlessInboxRoot;
      mode = "2770";
      user = "root";
      group = "paperless";
    }
    {
      path = vars.paperlessMailArchiveConsumeRoot;
      mode = "2770";
      user = "root";
      group = "paperless";
    }
    {
      path = vars.paperlessMailArchiveStagingRoot;
      mode = "0770";
      user = "mail-archive-ui";
      group = "mail-archive-ui";
    }
    {
      path = vars.paperlessArchiveRoot;
      mode = "0750";
      user = "paperless";
      group = "paperless";
    }
    {
      path = vars.paperlessExportRoot;
      mode = "0750";
      user = "paperless";
      group = "paperless";
    }
    {
      path = vars.sharedEmailsRoot;
      mode = "0770";
      user = "mail-archive-ui";
      group = "mail-archive-ui";
    }
  ] ++ map
    (path: {
      inherit path;
      mode = "2775";
      user = "root";
      group = "users";
    })
    (
      genericSharedContentDirs
        ++ [
        vars.sharedBooksRoot
        vars.sharedVideosRoot
      ]
        ++ sharedBooksDirs
        ++ sharedVideoDirs
    );

  sharedMediaAclScript = ''
    ${pkgs.acl}/bin/setfacl \
      -m 'g:mail-archive-ui:--x' \
      '${vars.sharedRoot}'

    apply_recursive_acl() {
      local access_spec="$1"
      local default_spec="$2"
      shift
      shift

      for path in "$@"; do
        [[ -d "$path" ]] || continue
        ${pkgs.acl}/bin/setfacl -R -m "$access_spec" "$path"
        ${pkgs.findutils}/bin/find "$path" -type d -exec ${pkgs.acl}/bin/setfacl -m "$default_spec" '{}' +
      done
    }

    apply_media_acl() {
      local group_name="$1"
      shift

      apply_recursive_acl "g:''${group_name}:rwX" "d:g:''${group_name}:rwx" "$@"
    }

    apply_media_acl audiobookshelf-media '${vars.sharedAudiobooksRoot}'
    apply_media_acl kavita-media ${lib.escapeShellArgs sharedKavitaDirs}
    apply_media_acl jellyfin-media ${lib.escapeShellArgs sharedJellyfinDirs}

    apply_readonly_acl() {
      local group_name="$1"
      shift

      apply_recursive_acl "g:''${group_name}:r-X" "d:g:''${group_name}:r-x" "$@"
    }

    apply_recursive_acl \
      "u:mail-archive-ui:rwX" \
      "d:u:mail-archive-ui:rwx" \
      '${vars.paperlessMailArchiveConsumeRoot}'
  '';

  zfsContentLayoutScript = lib.concatStringsSep "\n" (
    (map mkDirCmd zfsContentDirs)
    ++ [ sharedMediaAclScript ]
    ++ map mkImmichSentinelCmd [
      "${vars.immichManagedRoot}/backups/.immich"
      "${vars.immichManagedRoot}/encoded-video/.immich"
      "${vars.immichManagedRoot}/library/.immich"
      "${vars.immichManagedRoot}/profile/.immich"
      "${vars.immichManagedRoot}/thumbs/.immich"
      "${vars.immichManagedRoot}/upload/.immich"
    ]
  );
in
{
  users.groups.audiobookshelf-media = { };
  users.groups.kavita-media = { };
  users.groups.jellyfin-media = { };

  systemd.tmpfiles.rules = [
    "d /persist/appdata 0755 root root -"
    "d /persist/appdata/mail-archive-ui 0750 mail-archive-ui mail-archive-ui -"
    "d ${vars.coldStorageMountPoint} 0750 root root -"
  ] ++ map (pool: "d ${pool.mountPoint} 0750 root root -") vars.coldStoragePools;

  systemd.services.data-pool-layout = {
    description = "Provision data-pool-backed content layout";
    wantedBy = [ "multi-user.target" ];
    wants = [ "local-fs.target" ];
    after = [ "local-fs.target" ];
    before = managedUnits;
    unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      ensure_dataset() {
        local dataset="$1"
        local mountpoint="$2"

        if ! ${zfsBin} list -H -o name "$dataset" >/dev/null 2>&1; then
          ${zfsBin} create -o mountpoint="$mountpoint" "$dataset"
        else
          ${zfsBin} set canmount=on "$dataset"
          ${zfsBin} set mountpoint="$mountpoint" "$dataset"
          ${zfsBin} mount "$dataset" >/dev/null 2>&1 || true
        fi
      }

      ensure_dataset '${canonicalUsersDataset}' '${vars.usersRoot}'
      ensure_dataset '${canonicalSharedDataset}' '${vars.sharedRoot}'
      ${zfsContentLayoutScript}
    '';
  };
}
