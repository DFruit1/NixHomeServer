{ lib, pkgs, vars, ... }:

let
  zfsBin = "${pkgs.zfs}/bin/zfs";
  mailArchiveStoreRoot = "${vars.dataRoot}/mail-archive";
  legacyWorkspacesRoot = "${vars.dataRoot}/workspaces";
  legacyUsersRoot = "${legacyWorkspacesRoot}/users";
  legacySharedRoot = "${legacyWorkspacesRoot}/shared";
  canonicalUsersDataset = "${vars.zfsDataPool.name}/users";
  canonicalSharedDataset = "${vars.zfsDataPool.name}/shared";
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
  legacyOtherBooksRoot = "${vars.mediaRoot}/books/other";
  legacyMoviesRoot = "${vars.mediaRoot}/video/movies";
  legacyShowsRoot = "${vars.mediaRoot}/video/shows";
  legacyHomeVideosRoot = "${vars.mediaRoot}/video/home";
  legacyMusicVideosRoot = "${vars.mediaRoot}/video/music-videos";
  legacyYouTubeRoot = "${vars.mediaRoot}/video/youtube";
  legacyOtherVideosRoot = "${vars.mediaRoot}/video/other";
  genericSharedContentDirs = map (name: "${vars.sharedRoot}/${name}") (
    builtins.filter (name: name != "emails") vars.sharedContentSubdirs
  );
  sharedBooksDirs = map (name: "${vars.sharedBooksRoot}/${name}") vars.sharedBooksSubdirs;
  sharedVideoDirs = map (name: "${vars.sharedVideosRoot}/${name}") vars.sharedVideoSubdirs;
  sharedKavitaDirs = map (library: "${vars.sharedBooksRoot}/${library.dir}") vars.sharedKavitaLibraries;
  sharedJellyfinDirs = map (library: "${vars.sharedVideosRoot}/${library.dir}") vars.sharedJellyfinLibraries;
  managedUnits = [
    "audiobookshelf.service"
    "audiobookshelf-library-sync-v1.service"
    "copyparty.service"
    "fileshare-user-root-sync.service"
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

  migrationScript = ''
    set -euo pipefail

    marker_root="/persist/appdata/.nixos-managed/data-pool-layout-migration-v2"
    done_file="$marker_root/done"
    ${pkgs.coreutils}/bin/install -d -m 0755 /persist/appdata "$marker_root"

    if [[ -f "$done_file" ]]; then
      exit 0
    fi

    dir_has_entries() {
      local path="$1"
      [[ -d "$path" ]] || return 1
      ${pkgs.findutils}/bin/find "$path" -mindepth 1 -print -quit | ${pkgs.gnugrep}/bin/grep -q .
    }

    prune_empty_dirs() {
      local path="$1"
      [[ -d "$path" ]] || return 0
      ${pkgs.findutils}/bin/find "$path" -depth -type d -empty -delete
    }

    ensure_dir() {
      local path="$1"
      local mode="$2"
      local owner="$3"
      local group="$4"

      if [[ -e "$path" && ! -d "$path" ]]; then
        echo "Refusing to replace existing non-directory path: $path" >&2
        exit 1
      fi

      ${pkgs.coreutils}/bin/install -d -m "$mode" -o "$owner" -g "$group" "$path"
    }

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

    move_tree_contents() {
      local source_path="$1"
      local target_path="$2"
      local mode="$3"
      local owner="$4"
      local group="$5"
      local linked_source=""

      if [[ -L "$source_path" ]]; then
        linked_source="$(${pkgs.coreutils}/bin/readlink -f "$source_path" || true)"
        ${pkgs.coreutils}/bin/rm -f "$source_path"
        if [[ -z "$linked_source" || "$linked_source" == "$target_path" ]]; then
          return 0
        fi
        source_path="$linked_source"
      fi

      [[ -e "$source_path" ]] || return 0
      [[ -d "$source_path" ]] || {
        echo "Refusing to migrate non-directory path: $source_path" >&2
        exit 1
      }

      ensure_dir "$target_path" "$mode" "$owner" "$group"
      ${pkgs.rsync}/bin/rsync -aHAX --ignore-existing --remove-source-files "$source_path"/ "$target_path"/
      prune_empty_dirs "$source_path"

      if dir_has_entries "$source_path"; then
        echo "Migration left remaining content in $source_path; inspect conflicts manually." >&2
        exit 1
      fi

      ${pkgs.coreutils}/bin/rmdir "$source_path" 2>/dev/null || true
    }

    move_categorized_tree() {
      local source_root="$1"
      local target_root="$2"
      shift 2
      local category=""

      if [[ -L "$source_root" ]]; then
        local linked_source
        linked_source="$(${pkgs.coreutils}/bin/readlink -f "$source_root" || true)"
        ${pkgs.coreutils}/bin/rm -f "$source_root"
        if [[ -z "$linked_source" || "$linked_source" == "$target_root" ]]; then
          return 0
        fi
        source_root="$linked_source"
      fi

      [[ -e "$source_root" ]] || return 0
      [[ -d "$source_root" ]] || {
        echo "Refusing to migrate non-directory path: $source_root" >&2
        exit 1
      }

      for category in "$@"; do
        move_tree_contents "$source_root/$category" "$target_root/$category" 2775 root users
      done

      prune_empty_dirs "$source_root"
      if dir_has_entries "$source_root"; then
        echo "Migration left unexpected paths in $source_root; inspect manually." >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/rmdir "$source_root" 2>/dev/null || true
    }

    retire_legacy_dataset_if_empty() {
      local dataset="$1"
      local visible_path="$2"

      if ! ${zfsBin} list -H -o name "$dataset" >/dev/null 2>&1; then
        return 0
      fi

      if [[ -L "$visible_path" ]]; then
        ${pkgs.coreutils}/bin/rm -f "$visible_path"
      fi

      if [[ -d "$visible_path" ]]; then
        prune_empty_dirs "$visible_path"
        if dir_has_entries "$visible_path"; then
          return 0
        fi
        ${zfsBin} unmount "$dataset" >/dev/null 2>&1 || true
      fi

      ${zfsBin} set canmount=off "$dataset"
      ${zfsBin} set mountpoint=none "$dataset"
      if [[ -d "$visible_path" ]]; then
        ${pkgs.coreutils}/bin/rmdir "$visible_path" 2>/dev/null || true
      fi
    }

    ensure_dataset '${canonicalUsersDataset}' '${vars.usersRoot}'
    ensure_dataset '${canonicalSharedDataset}' '${vars.sharedRoot}'
    ${zfsContentLayoutScript}

    move_tree_contents '${legacyUsersRoot}' '${vars.usersRoot}' 0755 root root
    move_tree_contents '${legacySharedRoot}' '${vars.sharedRoot}' 2775 root users

    if [[ -d '${mailArchiveStoreRoot}/users' ]]; then
      shopt -s nullglob
      for legacy_user_root in '${mailArchiveStoreRoot}/users'/*; do
        [[ -d "$legacy_user_root" ]] || continue
        username="$(${pkgs.coreutils}/bin/basename "$legacy_user_root")"
        target_user_root='${vars.usersRoot}/'"$username"
        target_emails="$target_user_root/emails"

        ensure_dir "$target_user_root" 2770 root users
        move_tree_contents "$legacy_user_root" "$target_emails" 0770 mail-archive-ui mail-archive-ui
        ${pkgs.coreutils}/bin/chown -R mail-archive-ui:mail-archive-ui "$target_emails"
      done
      shopt -u nullglob
    fi

    shopt -s nullglob
    for user_videos_root in '${vars.usersRoot}'/*/videos; do
      move_categorized_tree \
        "$user_videos_root" \
        '${vars.sharedVideosRoot}' \
        movies shows home music-videos youtube other
    done
    shopt -u nullglob

    move_tree_contents '${legacyAudiobooksRoot}' '${vars.sharedAudiobooksRoot}' 2775 root users
    move_tree_contents '${legacyEbooksRoot}' '${vars.sharedEbooksRoot}' 2775 root users
    move_tree_contents '${legacyComicsRoot}' '${vars.sharedComicsRoot}' 2775 root users
    move_tree_contents '${legacyMangaRoot}' '${vars.sharedMangaRoot}' 2775 root users
    move_tree_contents '${legacyOtherBooksRoot}' '${vars.sharedOtherBooksRoot}' 2775 root users
    move_tree_contents '${legacyMoviesRoot}' '${vars.sharedMoviesRoot}' 2775 root users
    move_tree_contents '${legacyShowsRoot}' '${vars.sharedShowsRoot}' 2775 root users
    move_tree_contents '${legacyHomeVideosRoot}' '${vars.sharedHomeVideosRoot}' 2775 root users
    move_tree_contents '${legacyMusicVideosRoot}' '${vars.sharedMusicVideosRoot}' 2775 root users
    move_tree_contents '${legacyYouTubeRoot}' '${vars.sharedYouTubeRoot}' 2775 root users
    move_tree_contents '${legacyOtherVideosRoot}' '${vars.sharedOtherVideosRoot}' 2775 root users

    retire_legacy_dataset_if_empty '${vars.zfsDataPool.name}/workspaces' '${legacyWorkspacesRoot}'
    retire_legacy_dataset_if_empty '${vars.zfsDataPool.name}/mail-archive' '${mailArchiveStoreRoot}'

    ${pkgs.coreutils}/bin/touch "$done_file"
  '';
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

  systemd.services.data-pool-layout-migration-v2 = {
    description = "Migrate legacy data-pool layout into canonical user and shared roots";
    wantedBy = [ "multi-user.target" ];
    wants = [ "local-fs.target" ];
    after = [ "local-fs.target" ];
    before = [ "data-pool-layout.service" ] ++ managedUnits;
    unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = migrationScript;
  };

  systemd.services.data-pool-layout = {
    description = "Provision data-pool-backed content layout";
    wantedBy = [ "multi-user.target" ];
    wants = [ "local-fs.target" "data-pool-layout-migration-v2.service" ];
    after = [ "local-fs.target" "data-pool-layout-migration-v2.service" ];
    before = managedUnits;
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
