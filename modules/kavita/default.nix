{ config, lib, pkgs, vars, pkgsUnstable, ... }:

let
  libraryWatchers = import ../Core_Modules/library-watchers.nix { inherit pkgs; };
  kavitaPort = 5000;
  dataDir = "/var/lib/kavita";
  dbPath = "${dataDir}/config/kavita.db";
  kavitaPackage = pkgsUnstable.kavita.overrideAttrs (old: {
    backend = old.backend.overrideAttrs (backendOld: {
      patches = (backendOld.patches or [ ]) ++ [
        ./patches/fix-epub-relative-resource-resolution.patch
      ];
    });
  });
  sharedKavitaDirs = map (library: "${vars.sharedBooksRoot}/${library.dir}") vars.sharedKavitaLibraries;
  userBooksSubdirs = lib.escapeShellArgs vars.userBooksSubdirs;
  usersRootRegex = lib.escapeRegex vars.usersRoot;
  sharedRootRegex = lib.escapeRegex vars.sharedBooksRoot;
  watchRegex = "^(${sharedRootRegex}(/|$)|${usersRootRegex}/[^/]+/books(/|$))";
  watcherScript = libraryWatchers.mkSettledWatcherScript {
    name = "kavita-library-watch";
    watchedRoots = [
      vars.sharedBooksRoot
      vars.usersRoot
    ];
    triggerUnit = "kavita-library-sync.service";
    includeRegex = watchRegex;
    settleSeconds = 20;
    pollSeconds = 5;
  };
in
{
  services.kavita = {
    enable = true;
    package = kavitaPackage;
    dataDir = dataDir;
    tokenKeyFile = config.age.secrets.kavitaTokenKey.path;
    settings = {
      Port = kavitaPort;
      IpAddresses = "127.0.0.1,::1";
      OpenIdConnectSettings = {
        Enabled = true;
        Authority = vars.kanidmIssuer "kavita-web";
        ClientId = "kavita-web";
        Secret = "@OIDC_SECRET@";
        ProvisionAccounts = true;
        RequireVerifiedEmail = true;
        SyncUserSettings = true;
        RolesPrefix = "";
        RolesClaim = "kavita_roles";
        CustomScopes = [ "kavita_roles" ];
        DefaultRoles = [ ];
        DefaultLibraries = [ ];
        DefaultAgeRestriction = 0;
        DefaultIncludeUnknowns = false;
        AutoLogin = false;
        DisablePasswordAuthentication = true;
        ProviderName = "Kanidm";
      };
    };
  };

  users.users.kavita.extraGroups = lib.mkAfter [ "kavita-media" ];

  systemd.services.kavita.preStart = lib.mkAfter ''
    ${pkgs.replace-secret}/bin/replace-secret '@OIDC_SECRET@' \
      ${config.age.secrets.kavitaClientSecret.path} \
      '${dataDir}/config/appsettings.json'
  '';

  systemd.services.kavita = {
    after = [ "data-pool-layout.service" ];
    wants = [ "data-pool-layout.service" ];
  };

  systemd.services.kavita-oidc-bootstrap = {
    description = "Synchronize Kavita OIDC settings";
    wantedBy = [ "multi-user.target" ];
    after = [
      "kavita.service"
      "caddy.service"
      "kanidm.service"
    ];
    wants = [
      "kavita.service"
      "caddy.service"
      "kanidm.service"
    ];
    path = with pkgs; [
      jq
      sqlite
    ];
    script = ''
      set -euo pipefail

      db="${dataDir}/config/kavita.db"
      for _ in $(seq 1 30); do
        [[ -f "$db" ]] && break
        sleep 1
      done
      [[ -f "$db" ]] || {
        echo "Kavita database not found at $db" >&2
        exit 1
      }

      table_ready=""
      for _ in $(seq 1 30); do
        table_ready="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
          "select count(*) from sqlite_master where type = 'table' and name = 'ServerSetting';" \
          2>/dev/null || true)"
        [[ "$table_ready" == "1" ]] && break
        sleep 1
      done
      [[ "$table_ready" == "1" ]] || exit 0

      client_secret="$(< ${config.age.secrets.kavitaClientSecret.path})"
      current="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
        "select Value from ServerSetting where Key = 40;" 2>/dev/null || true)"
      [[ -n "$current" ]] || exit 0

      updated="$(printf '%s' "$current" | ${pkgs.jq}/bin/jq -c \
        --arg authority "${vars.kanidmIssuer "kavita-web"}" \
        --arg clientId "kavita-web" \
        --arg secret "$client_secret" \
        '
          .Authority = $authority
          | .ClientId = $clientId
          | .Secret = $secret
          | .ProvisionAccounts = true
          | .RequireVerifiedEmail = true
          | .SyncUserSettings = true
          | .RolesPrefix = ""
          | .RolesClaim = "kavita_roles"
          | .CustomScopes = ["kavita_roles"]
          | .DefaultRoles = []
          | .DefaultLibraries = []
          | .DefaultAgeRestriction = 0
          | .DefaultIncludeUnknowns = false
          | .Enabled = true
          | .AutoLogin = false
          | .DisablePasswordAuthentication = true
          | .ProviderName = "Kanidm"
        ')"

      if [[ "$current" == "$updated" ]]; then
        exit 0
      fi

      escaped="$(printf '%s' "$updated" | ${pkgs.perl}/bin/perl -pe 's/\x27/\x27\x27/g')"
      ${pkgs.sqlite}/bin/sqlite3 "$db" \
        "update ServerSetting set Value = '$escaped' where Key = 40;"
      /run/current-system/sw/bin/systemctl restart kavita.service
    '';
  };

  systemd.services.kavita-library-sync-config-v1 = {
    description = "Disable Kavita native folder watchers in favor of settled scans";
    wantedBy = [ "multi-user.target" ];
    after = [ "kavita.service" ];
    wants = [ "kavita.service" ];
    path = with pkgs; [ sqlite ];
    script = ''
      set -euo pipefail

      db=${lib.escapeShellArg dbPath}

      for _ in $(seq 1 30); do
        [[ -f "$db" ]] && break
        sleep 1
      done
      [[ -f "$db" ]] || exit 0

      current="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
        "select count(*) from Library where FolderWatching != 0;" 2>/dev/null || true)"
      [[ "$current" =~ ^[0-9]+$ ]] || exit 0

      if [[ "$current" != "0" ]]; then
        ${pkgs.sqlite}/bin/sqlite3 "$db" "update Library set FolderWatching = 0 where FolderWatching != 0;"
        /run/current-system/sw/bin/systemctl restart kavita.service
      fi
    '';
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  systemd.services.kavita-media-acl-sync-v1 = {
    description = "Converge Kavita media ACLs on book roots";
    wantedBy = [ "multi-user.target" ];
    after = [
      "data-pool-layout.service"
      "fileshare-user-root-sync.service"
    ];
    wants = [
      "data-pool-layout.service"
      "fileshare-user-root-sync.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = "5s";
    };
    path = with pkgs; [
      acl
      coreutils
      findutils
    ];
    script = ''
      set -euo pipefail

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

      apply_writable_acl() {
        local group_name="$1"
        shift

        apply_recursive_acl "g:''${group_name}:rwX" "d:g:''${group_name}:rwx" "$@"
      }

      declare -a book_roots=(
        ${lib.concatMapStringsSep "\n        " (path: ''"${path}"'') sharedKavitaDirs}
      )

      if [[ -d ${lib.escapeShellArg vars.usersRoot} ]]; then
        while IFS= read -r books_root; do
          book_roots+=("$books_root")
          for name in ${userBooksSubdirs}; do
            book_roots+=("$books_root/$name")
          done
        done < <(${pkgs.findutils}/bin/find ${lib.escapeShellArg vars.usersRoot} -mindepth 2 -maxdepth 2 -type d -name books -print | ${pkgs.coreutils}/bin/sort)
      fi

      if ((''${#book_roots[@]} > 0)); then
        apply_writable_acl kavita-media "''${book_roots[@]}"
      fi
    '';
  };

  systemd.services.kavita-library-sync = {
    description = "Run settled Kavita library scans";
    wantedBy = [ "multi-user.target" ];
    after = [
      "kavita.service"
      "kavita-media-acl-sync-v1.service"
      "kavita-library-sync-config-v1.service"
      "data-pool-layout.service"
    ];
    wants = [
      "kavita.service"
      "kavita-media-acl-sync-v1.service"
      "kavita-library-sync-config-v1.service"
      "data-pool-layout.service"
    ];
    path = with pkgs; [
      coreutils
      curl
      findutils
      gnused
      jq
      sqlite
    ];
    script = ''
      set -euo pipefail

      db=${lib.escapeShellArg dbPath}

      normalize_ebook_root_files() {
        local root="$1"

        [[ -d "$root" ]] || return 0

        while IFS= read -r file; do
          local filename stem target_dir target_path
          filename="$(basename "$file")"
          stem="''${filename%.*}"
          [[ -n "$stem" && "$stem" != "$filename" ]] || continue

          target_dir="$root/$stem"
          target_path="$target_dir/$filename"

          if [[ -e "$target_path" ]]; then
            echo "Skipping Kavita root cleanup because target already exists: $target_path" >&2
            continue
          fi

          mkdir -p "$target_dir"
          mv -- "$file" "$target_path"
          echo "Moved loose Kavita root file into its own folder: $file -> $target_path" >&2
        done < <(
          ${pkgs.findutils}/bin/find "$root" -maxdepth 1 -type f \
            \( \
              -iname '*.azw' -o \
              -iname '*.azw3' -o \
              -iname '*.cb7' -o \
              -iname '*.cbr' -o \
              -iname '*.cbt' -o \
              -iname '*.cbz' -o \
              -iname '*.chm' -o \
              -iname '*.djv' -o \
              -iname '*.djvu' -o \
              -iname '*.doc' -o \
              -iname '*.docx' -o \
              -iname '*.epub' -o \
              -iname '*.fb2' -o \
              -iname '*.htm' -o \
              -iname '*.html' -o \
              -iname '*.mobi' -o \
              -iname '*.pdb' -o \
              -iname '*.pdf' -o \
              -iname '*.rtf' -o \
              -iname '*.txt' -o \
              -iname '*.xps' -o \
              -iname '*.zip' \
            \) \
            -print \
            | ${pkgs.coreutils}/bin/sort
        )
      }

      api_key="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
        "select ApiKey from AspNetUsers where ApiKey is not null and length(ApiKey) > 0 order by case when UserName = '${vars.kanidmAdminUser}' then 0 else 1 end, Id limit 1;" \
        2>/dev/null || true)"
      [[ -n "$api_key" ]] || {
        echo "Kavita API key is not available yet; skipping scan"
        exit 0
      }

      auth_json="$(${pkgs.curl}/bin/curl \
        --silent \
        --show-error \
        --fail \
        -X POST \
        "http://127.0.0.1:${toString kavitaPort}/api/Plugin/authenticate?apiKey=$api_key&pluginName=nixos-kavita-library-sync-v1")"
      token="$(printf '%s' "$auth_json" | ${pkgs.jq}/bin/jq -r '.token')"
      [[ -n "$token" && "$token" != "null" ]] || {
        echo "Kavita authentication token was not returned" >&2
        exit 1
      }

      library_roots_json="$(${pkgs.sqlite}/bin/sqlite3 -readonly -json "$db" \
        "select l.Type as Type, fp.Path as Path from FolderPath fp join Library l on l.Id = fp.LibraryId order by fp.Path;" \
        2>/dev/null || true)"
      if [[ -z "$library_roots_json" ]]; then
        library_roots_json='[]'
      fi

      printf '%s' "$library_roots_json" | ${pkgs.jq}/bin/jq -c '.[] | select(.Type == 2) | .Path' | while IFS= read -r root_json; do
        root="$(printf '%s' "$root_json" | ${pkgs.jq}/bin/jq -r '.')"
        [[ -n "$root" && "$root" != "null" ]] || continue
        normalize_ebook_root_files "$root"
      done

      if [[ "$library_roots_json" != "[]" ]]; then
        invalid_roots="$(${pkgs.curl}/bin/curl \
          --silent \
          --show-error \
          --fail \
          -X POST \
          -H "Authorization: Bearer $token" \
          -H 'Content-Type: application/json' \
          --data "$(printf '%s' "$library_roots_json" | ${pkgs.jq}/bin/jq -c '{ roots: [.[].Path] }')" \
          "http://127.0.0.1:${toString kavitaPort}/api/Library/has-files-at-root")"
        if [[ "$invalid_roots" != "[]" ]]; then
          echo "Kavita root-file warning: supported files were uploaded directly at a library root" >&2
          printf '%s' "$invalid_roots" | ${pkgs.jq}/bin/jq -r '.[]' | while IFS= read -r root; do
            [[ -n "$root" ]] || continue
            echo "Invalid Kavita library root: $root" >&2
            ${pkgs.findutils}/bin/find "$root" -maxdepth 1 -type f | sed 's/^/  root file: /' >&2 || true
          done
        fi
      fi

      ${pkgs.curl}/bin/curl \
        --silent \
        --show-error \
        --fail \
        -X POST \
        -H "Authorization: Bearer $token" \
        "http://127.0.0.1:${toString kavitaPort}/api/Library/scan-all" \
        >/dev/null
    '';
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  systemd.services.kavita-library-watch = {
    description = "Watch book roots and debounce Kavita scans";
    wantedBy = [ "multi-user.target" ];
    after = [
      "kavita.service"
      "kavita-library-sync.service"
      "data-pool-layout.service"
    ];
    wants = [
      "kavita.service"
      "kavita-library-sync.service"
      "data-pool-layout.service"
    ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${watcherScript}";
      Restart = "always";
      RestartSec = "5s";
    };
  };
}
