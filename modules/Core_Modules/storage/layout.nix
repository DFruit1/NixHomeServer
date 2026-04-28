{ lib, pkgs, vars, ... }:

let
  zfsBin = "${pkgs.zfs}/bin/zfs";
  canonicalUsersDataset = "${vars.zfsDataPool.name}/users";
  canonicalSharedDataset = "${vars.zfsDataPool.name}/shared";
  immichManagedPhotosRoot = "${vars.mediaRoot}/photos/managed";
  immichExternalPhotosRoot = "${vars.mediaRoot}/photos/external";
  paperlessInboxDir = "${vars.mediaRoot}/documents/inbox";
  paperlessMailArchiveConsumeRoot = "${vars.mediaRoot}/documents/inbox/mail-archive";
  paperlessMailArchiveStagingDir = "${vars.mediaRoot}/documents/.mail-archive-paperless-staging";
  paperlessArchiveDir = "${vars.mediaRoot}/documents/archive";
  paperlessExportDir = "${vars.mediaRoot}/documents/export";
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
    "samba-smbd.service"
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
      path = vars.mediaRoot;
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
      path = immichManagedPhotosRoot;
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = "${immichManagedPhotosRoot}/backups";
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = "${immichManagedPhotosRoot}/encoded-video";
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = "${immichManagedPhotosRoot}/library";
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = "${immichManagedPhotosRoot}/profile";
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = "${immichManagedPhotosRoot}/thumbs";
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = "${immichManagedPhotosRoot}/upload";
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = immichExternalPhotosRoot;
      mode = "2770";
      user = "root";
      group = "immich";
    }
    {
      path = paperlessInboxDir;
      mode = "2770";
      user = "root";
      group = "paperless";
    }
    {
      path = paperlessMailArchiveConsumeRoot;
      mode = "2770";
      user = "root";
      group = "paperless";
    }
    {
      path = paperlessMailArchiveStagingDir;
      mode = "0770";
      user = "mail-archive-ui";
      group = "mail-archive-ui";
    }
    {
      path = paperlessArchiveDir;
      mode = "0750";
      user = "paperless";
      group = "paperless";
    }
    {
      path = paperlessExportDir;
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
      -m 'g:immich:--x' \
      -m 'g:paperless:--x' \
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

    apply_readonly_acl immich '${vars.sharedRoot}/photos'
    apply_readonly_acl paperless '${vars.sharedRoot}/documents'
    apply_recursive_acl \
      "u:mail-archive-ui:rwX" \
      "d:u:mail-archive-ui:rwx" \
      '${paperlessMailArchiveConsumeRoot}'
  '';

  zfsContentLayoutScript = lib.concatStringsSep "\n" (
    (map mkDirCmd zfsContentDirs)
    ++ [ sharedMediaAclScript ]
    ++ map mkImmichSentinelCmd [
      "${immichManagedPhotosRoot}/backups/.immich"
      "${immichManagedPhotosRoot}/encoded-video/.immich"
      "${immichManagedPhotosRoot}/library/.immich"
      "${immichManagedPhotosRoot}/profile/.immich"
      "${immichManagedPhotosRoot}/thumbs/.immich"
      "${immichManagedPhotosRoot}/upload/.immich"
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
