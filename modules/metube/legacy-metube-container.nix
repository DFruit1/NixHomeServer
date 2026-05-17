{ config, pkgs, vars, ... }:

let
  metubeUser = "metube";
  metubeGroup = "metube";
  metubeUid = 3002;
  metubeGid = 3002;
  metubeSubIdStart = 465536;
  metubeSubIdCount = 65536;
  metubeListenAddress = vars.networking.loopbackIPv4;
  metubeListenPort = vars.networking.ports.metube;
  metubeContainerPort = vars.networking.ports.metubeContainer;
  metubeHome = "/var/lib/metube";
  metubeStateDir = "${metubeHome}/state";
  metubeTempDir = "${metubeHome}/tmp";
  metubeImage = "ghcr.io/alexta69/metube@sha256:ee9a49b477215d33a8c330e9b9bb5c70588e265637cba9ff3888b75b87c00bf0";
  metubeVersion = "2026.04.26";
  metubePatchedMain = pkgs.stdenvNoCC.mkDerivation {
    pname = "metube-patched-main";
    version = metubeVersion;
    src = pkgs.fetchFromGitHub {
      owner = "alexta69";
      repo = "metube";
      rev = metubeVersion;
      hash = "sha256-WTirLBPCOZQod0GasJl+LvM2FzQKbep3SEx5996X5wA=";
    };
    patches = [
      ./patches/ignore-url-t-clip-start.patch
      ./patches/audio-downloads-to-authenticated-user-audiobooks.patch
    ];
    installPhase = ''
      mkdir -p $out
      cp app/main.py $out/main.py
      cp app/ytdl.py $out/ytdl.py
    '';
  };
  outputTemplate = "%(channel,uploader,creator|Unknown Channel)S/%(upload_date>%Y,release_date>%Y|Unknown Year)s/%(upload_date>%Y-%m-%d,release_date>%Y-%m-%d|Unknown Date)s - %(title|Unknown Title)S [%(id|NOID)s].%(ext)s";
  outputTemplateChapter = "%(channel,uploader,creator|Unknown Channel)S/%(upload_date>%Y,release_date>%Y|Unknown Year)s/%(upload_date>%Y-%m-%d,release_date>%Y-%m-%d|Unknown Date)s - %(title|Unknown Title)S [%(id|NOID)s] - %(section_number)02d %(section_title|Chapter)S.%(ext)s";
  audioOutputTemplate = "%(title|Unknown Title)S [%(id|NOID)s].%(ext)s";
  escapedOutputTemplate = builtins.replaceStrings [ "%" ] [ "%%" ] outputTemplate;
  escapedOutputTemplateChapter = builtins.replaceStrings [ "%" ] [ "%%" ] outputTemplateChapter;
  escapedAudioOutputTemplate = builtins.replaceStrings [ "%" ] [ "%%" ] audioOutputTemplate;
  ytOptionsJson = builtins.toJSON {
    format = "bestvideo[vcodec*=avc1]+bestaudio[acodec*=mp4a]/best";
    merge_output_format = "mkv";
    writethumbnail = true;
    postprocessors = [
      {
        key = "FFmpegMetadata";
        add_metadata = true;
        add_chapters = true;
        add_infojson = "if_exists";
      }
      {
        key = "EmbedThumbnail";
      }
    ];
  };
  ytOptionsEnv = builtins.replaceStrings [ "\"" ] [ "\\\"" ] ytOptionsJson;
  resources = config.nixhomeserver.resources;
in
{
  virtualisation.podman.enable = true;
  users.manageLingering = true;

  users.groups.${metubeGroup} = {
    gid = metubeGid;
  };

  users.users.${metubeUser} = {
    isSystemUser = true;
    uid = metubeUid;
    group = metubeGroup;
    extraGroups = [ "users" ];
    home = metubeHome;
    createHome = true;
    linger = true;
    subUidRanges = [
      {
        startUid = metubeSubIdStart;
        count = metubeSubIdCount;
      }
    ];
    subGidRanges = [
      {
        startGid = metubeSubIdStart;
        count = metubeSubIdCount;
      }
    ];
  };

  systemd.tmpfiles.rules = [
    "d ${metubeStateDir} 0750 ${metubeUser} ${metubeGroup} -"
    "d ${metubeTempDir} 0750 ${metubeUser} ${metubeGroup} -"
  ];

  environment.etc."containers/systemd/users/${toString metubeUid}/metube.container".text = ''
    [Container]
    Image=${metubeImage}
    ContainerName=metube
    PublishPort=${metubeListenAddress}:${toString metubeListenPort}:${toString metubeContainerPort}
    Volume=${vars.sharedYouTubeRoot}:/downloads:rw
    Volume=${vars.usersRoot}:/user-audiobooks:rw
    Volume=${metubeStateDir}:/state:rw
    Volume=${metubeTempDir}:/tmp-downloads:rw
    Volume=${metubePatchedMain}/main.py:/app/app/main.py:ro
    Volume=${metubePatchedMain}/ytdl.py:/app/app/ytdl.py:ro
    Environment=DOWNLOAD_DIR=/downloads
    Environment=AUDIO_DOWNLOAD_DIR=/user-audiobooks
    Environment=STATE_DIR=/state
    Environment=TEMP_DIR=/tmp-downloads
    Environment=PUID=${toString metubeUid}
    Environment=PGID=${toString metubeGid}
    Environment=UMASK=002
    Environment=CHOWN_DIRS=false
    Environment=CUSTOM_DIRS=false
    Environment=CREATE_CUSTOM_DIRS=false
    Environment=DOWNLOAD_DIRS_INDEXABLE=false
    Environment=ALLOW_YTDL_OPTIONS_OVERRIDES=false
    Environment="OUTPUT_TEMPLATE=${escapedOutputTemplate}"
    Environment="AUDIO_OUTPUT_TEMPLATE=${escapedAudioOutputTemplate}"
    Environment=OUTPUT_TEMPLATE_PLAYLIST=
    Environment=OUTPUT_TEMPLATE_CHANNEL=
    Environment="OUTPUT_TEMPLATE_CHAPTER=${escapedOutputTemplateChapter}"
    Environment="YTDL_OPTIONS=${ytOptionsEnv}"
    Pull=missing
    NoNewPrivileges=true
    DropCapability=all
    PodmanArgs=--userns=keep-id
    PodmanArgs=--group-add=keep-groups

    [Service]
    Restart=on-failure
    TimeoutStartSec=900
    CPUQuota=${resources.metube.cpuQuota}

    [Install]
    WantedBy=default.target
  '';

  systemd.services.metube-quadlet-refresh = {
    description = "Refresh MeTube rootless quadlet";
    after = [
      "data-pool-layout.service"
      "network-online.target"
      "user@${toString metubeUid}.service"
    ];
    requires = [
      "data-pool-layout.service"
      "user@${toString metubeUid}.service"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [
      config.environment.etc."containers/systemd/users/${toString metubeUid}/metube.container".source
    ];
    serviceConfig.Type = "oneshot";
    script = ''
      export XDG_RUNTIME_DIR=/run/user/${toString metubeUid}
      export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${toString metubeUid}/bus
      ${pkgs.util-linux}/bin/runuser -u ${metubeUser} -- ${pkgs.systemd}/bin/systemctl --user daemon-reload
      ${pkgs.util-linux}/bin/runuser -u ${metubeUser} -- ${pkgs.systemd}/bin/systemctl --user restart metube.service
    '';
  };
}
