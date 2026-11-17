{ config, lib, options, pkgs, vars, ... }:

let
  immich = config.services.immich;
  database = immich.database.name;
  # Exactly the columns Search reads (custom_apps/rust/apps/search/src/
  # extract/immich.rs). Nothing else in the photo library's database is
  # visible to it: no file paths, checksums, faces, sessions, keys or
  # settings.
  columns = {
    asset = [ "id" "ownerId" "type" "originalFileName" "fileCreatedAt" "localDateTime" "deletedAt" "status" "visibility" "isFavorite" ];
    user = [ "id" "storageLabel" "name" ];
    asset_exif = [ "assetId" "city" "state" "country" "make" "model" "description" ];
    album_asset = [ "assetId" "albumId" ];
    album = [ "id" "albumName" "deletedAt" ];
    asset_face = [ "assetId" "personGroupId" "deletedAt" "isVisible" ];
    person = [ "personGroupId" "name" "isHidden" ];
    tag_asset = [ "assetId" "tagId" ];
    tag = [ "id" "value" ];
    ocr_search = [ "assetId" "text" ];
    smart_search = [ "assetId" "embedding" ];
  };
  quote = name: ''"${name}"'';
  grants = pkgs.writeText "search-immich-access.sql" ''
    REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM search;
    GRANT CONNECT ON DATABASE ${quote database} TO search;
    GRANT USAGE ON SCHEMA public TO search;
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList
      (table: names: "GRANT SELECT (${lib.concatMapStringsSep ", " quote names}) ON ${quote table} TO search;")
      columns)}
  '';
in
{
  config = lib.optionalAttrs
    (lib.hasAttrByPath [ "repo" "search" ] options)
    (lib.mkIf (config.repo.search.enable && immich.enable) {
      # Photos are indexed by what Immich already knows about them (place,
      # date, albums, named people, text in the picture) and, when a search
      # is restricted to photos, found by what they show through Immich's own
      # image model. Nothing is recognised or tagged a second time.
      repo.search.sources.immich = {
        displayName = "Photos";
        sourceType = "immich";
        appBase = "https://photos.${vars.domain}";
        settings = {
          databaseUrl = "postgresql:///?host=/run/postgresql&user=search&dbname=${database}";
          # Immich files the server administrator under the label "admin".
          adminOwner = vars.kanidmAdminUser;
          embedUrl = "http://${vars.networking.loopbackIPv4}:3003";
          clipModel = immich.settings.machineLearning.clip.modelName;
        };
      };

      # A read-only database role limited to the listed columns. Re-applied
      # at boot and after an Immich upgrade; if an upgrade renames a column
      # this unit fails and photo indexing reports the error, while every
      # other source keeps working.
      systemd.services.search-immich-access = {
        description = "Grant Search read-only access to selected photo library columns";
        wantedBy = [ "multi-user.target" ];
        wants = [ "immich-server.service" ];
        after = [ "postgresql.service" "immich-server.service" ];
        before = [ "search-index.service" ];
        restartTriggers = [ grants ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "postgres";
          Group = "postgres";
          ExecStart = "${config.services.postgresql.package}/bin/psql -X -v ON_ERROR_STOP=1 --single-transaction -d ${database} -f ${grants}";
          Restart = "on-failure";
          RestartSec = "60s";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
        };
      };
      systemd.services.search-index.wants = [ "search-immich-access.service" ];
    });
}
