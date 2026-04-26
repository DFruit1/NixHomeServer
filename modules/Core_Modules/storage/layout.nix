{ lib, pkgs, vars, ... }:

let
  mailArchiveStoreRoot = "${vars.dataRoot}/mail-archive";
  workspaceStorageRoot = "${vars.dataRoot}/workspaces";
  backingUsersRoot = "${workspaceStorageRoot}/users";
  backingSharedRoot = "${workspaceStorageRoot}/shared";
  immichManagedPhotosRoot = "${vars.mediaRoot}/photos/managed";
  immichExternalPhotosRoot = "${vars.mediaRoot}/photos/external";
  paperlessInboxDir = "${vars.mediaRoot}/documents/inbox";
  paperlessMailArchiveConsumeRoot = "${vars.mediaRoot}/documents/inbox/mail-archive";
  paperlessMailArchiveStagingDir = "${vars.mediaRoot}/documents/.mail-archive-paperless-staging";
  paperlessArchiveDir = "${vars.mediaRoot}/documents/archive";
  paperlessExportDir = "${vars.mediaRoot}/documents/export";
  podcastsRoot = "${vars.mediaRoot}/audio/podcasts";
  legacyAudiobooksRoot = "${vars.mediaRoot}/audio/audiobooks";
  legacyEbooksRoot = "${vars.mediaRoot}/books/ebooks";
  legacyComicsRoot = "${vars.mediaRoot}/books/comics";
  legacyMangaRoot = "${vars.mediaRoot}/books/manga";
  legacyMoviesRoot = "${vars.mediaRoot}/video/movies";
  legacyShowsRoot = "${vars.mediaRoot}/video/shows";
  legacyHomeVideosRoot = "${vars.mediaRoot}/video/home";
  genericSharedContentDirs = map (name: "${vars.sharedPublicRoot}/${name}") (
    builtins.filter (name: name != "emails") vars.sharedContentSubdirs
  );
  sharedBooksDirs = map (name: "${vars.sharedBooksRoot}/${name}") vars.sharedBooksSubdirs;
  sharedVideoDirs = map (name: "${vars.sharedVideosRoot}/${name}") vars.sharedVideoSubdirs;
  sharedKavitaDirs = map (library: "${vars.sharedBooksRoot}/${library.dir}") vars.sharedKavitaLibraries;
  sharedJellyfinDirs = map (library: "${vars.sharedVideosRoot}/${library.dir}") vars.sharedJellyfinLibraries;

  mkDirCmd =
    {
      path,
      mode,
      user,
      group,
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
      path = "${vars.mediaRoot}/audio";
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = "${vars.mediaRoot}/books";
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = "${vars.mediaRoot}/video";
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = vars.usersWorkspaceRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = vars.sharedPublicRoot;
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
      path = podcastsRoot;
      mode = "2775";
      user = "root";
      group = "users";
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

  materializeDirectRootScript = ''
    materialize_root_from_legacy() {
      local target_path="$1"
      local legacy_path="$2"
      local mode="$3"
      local owner="$4"
      local group="$5"
      local linked_source=""

      if [[ -L "$target_path" ]]; then
        linked_source="$(${pkgs.coreutils}/bin/readlink -f "$target_path" || true)"
        ${pkgs.coreutils}/bin/rm -f "$target_path"
      elif [[ -e "$target_path" && ! -d "$target_path" ]]; then
        echo "Refusing to replace existing non-directory path: $target_path" >&2
        exit 1
      fi

      ${pkgs.coreutils}/bin/install -d -m "$mode" -o "$owner" -g "$group" "$target_path"

      for source_path in "$linked_source" "$legacy_path"; do
        [[ -n "$source_path" && -d "$source_path" && "$source_path" != "$target_path" ]] || continue
        ${pkgs.rsync}/bin/rsync -a --ignore-existing "$source_path"/ "$target_path"/
      done

      ${pkgs.coreutils}/bin/chown "$owner:$group" "$target_path"
      ${pkgs.coreutils}/bin/chmod "$mode" "$target_path"
    }

    materialize_root_from_legacy '${vars.usersWorkspaceRoot}' '${backingUsersRoot}' 0755 root root
    materialize_root_from_legacy '${vars.sharedPublicRoot}' '${backingSharedRoot}' 2775 root users
  '';

  legacyMailArchiveMigrationScript = ''
    legacy_mail_root='${mailArchiveStoreRoot}/users'
    ${pkgs.coreutils}/bin/install -d -m 0770 -o mail-archive-ui -g mail-archive-ui '${vars.sharedEmailsRoot}'

    if [[ -d "$legacy_mail_root" ]]; then
      for legacy_user_root in "$legacy_mail_root"/*; do
        [[ -d "$legacy_user_root" ]] || continue
        username="$(${pkgs.coreutils}/bin/basename "$legacy_user_root")"
        target_user_root='${vars.usersWorkspaceRoot}/'"$username"
        target_emails="$target_user_root/emails"

        ${pkgs.coreutils}/bin/install -d -m 2770 -o root -g users "$target_user_root"
        if [[ -L "$target_emails" ]]; then
          ${pkgs.coreutils}/bin/rm -f "$target_emails"
        elif [[ -e "$target_emails" && ! -d "$target_emails" ]]; then
          echo "Refusing to replace existing non-directory path: $target_emails" >&2
          exit 1
        fi

        ${pkgs.coreutils}/bin/install -d -m 0770 -o mail-archive-ui -g mail-archive-ui "$target_emails"
        ${pkgs.rsync}/bin/rsync -a --ignore-existing "$legacy_user_root"/ "$target_emails"/
        ${pkgs.coreutils}/bin/chown -R mail-archive-ui:mail-archive-ui "$target_emails"
      done
    fi
  '';

  legacySharedSymlinkScript = ''
    migrate_dir_to_symlink() {
      local source_path="$1"
      local target_path="$2"

      ${pkgs.coreutils}/bin/install -d -m 2775 -o root -g users "$(${pkgs.coreutils}/bin/dirname "$target_path")"
      ${pkgs.coreutils}/bin/install -d -m 2775 -o root -g users "$target_path"

      if [[ -L "$source_path" ]]; then
        ${pkgs.coreutils}/bin/ln -sfn "$target_path" "$source_path"
        return
      fi

      if [[ -d "$source_path" ]]; then
        ${pkgs.rsync}/bin/rsync -a --ignore-existing "$source_path"/ "$target_path"/
        ${pkgs.coreutils}/bin/rm -rf "$source_path"
      elif [[ -e "$source_path" ]]; then
        echo "Refusing to replace existing non-directory path: $source_path" >&2
        exit 1
      fi

      ${pkgs.coreutils}/bin/ln -sfn "$target_path" "$source_path"
    }

    migrate_dir_to_symlink '${legacyAudiobooksRoot}' '${vars.sharedAudiobooksRoot}'
    migrate_dir_to_symlink '${legacyEbooksRoot}' '${vars.sharedEbooksRoot}'
    migrate_dir_to_symlink '${legacyComicsRoot}' '${vars.sharedComicsRoot}'
    migrate_dir_to_symlink '${legacyMangaRoot}' '${vars.sharedMangaRoot}'
    migrate_dir_to_symlink '${legacyMoviesRoot}' '${vars.sharedMoviesRoot}'
    migrate_dir_to_symlink '${legacyShowsRoot}' '${vars.sharedShowsRoot}'
    migrate_dir_to_symlink '${legacyHomeVideosRoot}' '${vars.sharedHomeVideosRoot}'
  '';

  personalVideoMigrationScript = ''
    migrate_personal_videos_into_shared() {
      local user_videos_root="$1"
      local category=""
      local source_dir=""
      local target_dir=""

      [[ -e "$user_videos_root" ]] || return 0
      [[ -d "$user_videos_root" ]] || {
        echo "Refusing to migrate non-directory personal videos root: $user_videos_root" >&2
        exit 1
      }

      for category in movies shows home music-videos youtube other; do
        source_dir="$user_videos_root/$category"
        target_dir='${vars.sharedVideosRoot}/'"$category"

        [[ -e "$source_dir" ]] || continue
        [[ -d "$source_dir" ]] || {
          echo "Refusing to migrate non-directory personal video category: $source_dir" >&2
          exit 1
        }

        ${pkgs.coreutils}/bin/install -d -m 2775 -o root -g users "$target_dir"
        ${pkgs.rsync}/bin/rsync -a --ignore-existing --remove-source-files "$source_dir"/ "$target_dir"/
        ${pkgs.findutils}/bin/find "$source_dir" -depth -type d -empty -delete

        if [[ -d "$source_dir" ]] && ${pkgs.findutils}/bin/find "$source_dir" -mindepth 1 -print -quit | ${pkgs.gnugrep}/bin/grep -q .; then
          echo "Personal video migration left remaining content in $source_dir; inspect conflicts manually." >&2
        fi
      done

      ${pkgs.findutils}/bin/find "$user_videos_root" -depth -type d -empty -delete
      if [[ -d "$user_videos_root" ]] && ${pkgs.findutils}/bin/find "$user_videos_root" -mindepth 1 -print -quit | ${pkgs.gnugrep}/bin/grep -q .; then
        echo "Personal video migration left remaining content in $user_videos_root; inspect unexpected paths manually." >&2
      fi
    }

    shopt -s nullglob
    for user_videos_root in '${vars.usersWorkspaceRoot}'/*/videos; do
      migrate_personal_videos_into_shared "$user_videos_root"
    done
    shopt -u nullglob
  '';

  sharedMediaAclScript = ''
    ${pkgs.acl}/bin/setfacl \
      -m 'g:mail-archive-ui:--x' \
      -m 'g:immich:--x' \
      -m 'g:paperless:--x' \
      '${vars.sharedPublicRoot}'

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

    apply_readonly_acl immich '${vars.sharedPublicRoot}/photos'
    apply_readonly_acl paperless '${vars.sharedPublicRoot}/documents'
    apply_recursive_acl \
      "u:mail-archive-ui:rwX" \
      "d:u:mail-archive-ui:rwx" \
      '${paperlessMailArchiveConsumeRoot}'
  '';

  zfsContentLayoutScript = lib.concatStringsSep "\n" (
    (map mkDirCmd zfsContentDirs)
    ++ [
      materializeDirectRootScript
      legacyMailArchiveMigrationScript
      legacySharedSymlinkScript
      personalVideoMigrationScript
      sharedMediaAclScript
    ]
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
    before = [
      "audiobookshelf.service"
      "audiobookshelf-library-sync-v1.service"
      "copyparty.service"
      "jellyfin.service"
      "jellyfin-reconcile-v1.service"
      "kavita.service"
      "kavita-library-sync-v1.service"
      "mail-archive-sync.service"
      "mail-archive-ui.service"
      "paperless-consumer.service"
      "paperless-scheduler.service"
      "paperless-task-queue.service"
      "paperless-web.service"
      "samba-smbd.service"
    ];
    unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      ${zfsContentLayoutScript}
    '';
  };
}
