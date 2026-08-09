{ config, lib, pkgs, vars, jellyfinMetadataPlugins, ... }:

let
  dataDir = "/var/lib/jellyfin";
  pluginsDir = "${dataDir}/plugins";
  loopback = vars.networking.loopbackIPv4;
  jellyfinPort = vars.networking.ports.jellyfin;
  jellyfinUrl = "http://${loopback}:${toString jellyfinPort}";
  apiKeyFile = "${dataDir}/data/library-sync.api-key";

  pluginDirs = builtins.listToAttrs (map
    (plugin: {
      name = "${pluginsDir}/${plugin.pluginDirName}";
      value = plugin;
    })
    jellyfinMetadataPlugins);

  metadataPluginInstaller = pkgs.writeShellApplication {
    name = "jellyfin-metadata-plugins-install";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      set -euo pipefail
      dest_plugins_dir=${lib.escapeShellArg pluginsDir}
    '' + lib.concatMapStringsSep "\n" (plugin: ''
      src_dir="${plugin.drv}/lib"
      dest_dir="$dest_plugins_dir/${plugin.pluginDirName}"
      for src_file in "$src_dir"/*; do
        [[ -f "$src_file" ]] || continue
        fname="$(basename "$src_file")"
        install -m 0444 "$src_file" "$dest_dir/$fname"
      done
    '') jellyfinMetadataPlugins;
  };

  metadataConfigJson = pkgs.writeText "jellyfin-metadata-config.json" ''
    {
      "Movie": {
        "MetadataFetcherOrder": ["TheMovieDb"],
        "ImageFetcherOrder": ["Fanart", "TheMovieDb", "Screen Grabber", "Embedded Image Extraction"]
      },
      "Series": {
        "MetadataFetcherOrder": ["TheMovieDb", "TheTVDB"],
        "ImageFetcherOrder": ["Fanart", "TheMovieDb", "TheTVDB", "Screen Grabber", "Embedded Image Extraction"]
      },
      "MusicAlbum": {
        "MetadataFetcherOrder": ["MusicBrainz", "TheAudioDB"],
        "ImageFetcherOrder": ["Cover Art Archive", "Embedded Image Extraction", "Screen Grabber"]
      }
    }
  '';
in
{
  config = {
    systemd.tmpfiles.settings = lib.mkMerge (map
      (plugin: {
        "jellyfin-metadata-${plugin.pluginDirName}"."${pluginsDir}/${plugin.pluginDirName}".d = {
          mode = "0750";
          user = "jellyfin";
          group = "jellyfin";
        };
      })
      jellyfinMetadataPlugins);

    systemd.services.jellyfin = {
      restartTriggers = map (plugin: plugin.drv) jellyfinMetadataPlugins;
      serviceConfig.ExecStartPre = lib.mkAfter [
        "${metadataPluginInstaller}/bin/jellyfin-metadata-plugins-install"
      ];
    };

    systemd.services.jellyfin-metadata-bootstrap-v1 = {
      description = "Reconcile Jellyfin metadata provider ordering and preferences";
      wantedBy = [ "multi-user.target" ];
      wants = [ "jellyfin.service" ];
      after = [ "jellyfin.service" ];
      path = with pkgs; [
        coreutils
        curl
        diffutils
        jq
      ];
      script = ''
        set -euo pipefail

        api_key_file=${lib.escapeShellArg apiKeyFile}
        api_url=${lib.escapeShellArg jellyfinUrl}
        config_src=${lib.escapeShellArg metadataConfigJson}
        system_config_url="$api_url/System/Configuration"

        [[ -s "$api_key_file" ]] || {
          echo "Jellyfin bootstrap API key not found; waiting for library sync." >&2
          exit 1
        }

        api_key="$(tr -d '\r\n' <"$api_key_file")"
        [[ -n "$api_key" ]] || {
          echo "Jellyfin metadata bootstrap API key is empty." >&2
          exit 1
        }

        api_get() {
          curl --fail --silent --show-error \
            --header "X-Emby-Token: $api_key" \
            "$1"
        }

        api_post() {
          local url="$1"
          local body_file="$2"
          curl --fail --silent --show-error \
            --request POST \
            --header "X-Emby-Token: $api_key" \
            --header "Content-Type: application/json" \
            --data-binary "@$body_file" \
            "$url" >/dev/null
        }

        ready=0
        for _ in $(seq 1 60); do
          if api_get "$api_url/System/Info/Public" >/dev/null 2>&1; then
            ready=1
            break
          fi
          sleep 2
        done
        (( ready == 1 )) || {
          echo "Jellyfin did not become ready for metadata bootstrap." >&2
          exit 1
        }

        work_dir="$(mktemp -d)"
        trap 'rm -rf "$work_dir"' EXIT
        current_config="$work_dir/current-config.json"
        desired_config="$work_dir/desired-config.json"

        api_get "$system_config_url" >"$current_config"

        jq -s '
          .[0] as $current
          | .[1] as $desired_overrides
          | $current
          | .MetadataOptions |= (
              map(
                . as $opt
                | $desired_overrides[$opt.ItemType // ""] as $override
                | if $override then
                    $opt
                    | .MetadataFetcherOrder = ($override.MetadataFetcherOrder // .MetadataFetcherOrder)
                    | .ImageFetcherOrder = ($override.ImageFetcherOrder // .ImageFetcherOrder)
                  else
                    $opt
                  end
              )
            )
        ' "$current_config" "$config_src" >"$desired_config"

        if ! cmp -s "$current_config" "$desired_config"; then
          api_post "$system_config_url" "$desired_config"
          echo "Jellyfin metadata provider ordering reconciled."
        else
          echo "Jellyfin metadata provider ordering already converged."
        fi

        for _ in $(seq 1 10); do
          if api_get "$api_url/Library/VirtualFolders" >/dev/null 2>&1; then
            break
          fi
          sleep 2
        done

        libraries_json="$work_dir/libraries.json"
        api_get "$api_url/Library/VirtualFolders" >"$libraries_json"

        library_ids="$(jq -r '.[] | select(.ItemId != null) | .ItemId' "$libraries_json")"
        for lib_id in $library_ids; do
          [[ -n "$lib_id" ]] || continue
          api_post "$api_url/Items/$lib_id/Refresh" /dev/null 2>/dev/null || true
        done

        echo "Triggered metadata refresh for all Jellyfin libraries."
      '';
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ dataDir ];
      };
      unitConfig = lib.mkMerge [
        { RequiresMountsFor = [ vars.dataRoot ]; }
        (lib.mkIf vars.dataRootIsMountPoint {
          ConditionPathIsMountPoint = vars.dataRoot;
        })
      ];
    };
  };
}
