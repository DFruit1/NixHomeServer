{ lib }:

cfg:

let
  musicFolderName = cfg.musicFolderName or cfg.folderName or "_Music";
  defaultFolderSpecs = [
    {
      key = "music";
      label = "Music";
      relativePath = musicFolderName;
      folderIdPrefix = cfg.musicFolderIdPrefix or cfg.folderIdPrefix or "nixhomeserver-music";
      suggestedDevicePath = "Music/NixHomeServer";
    }
    {
      key = "youtube";
      label = "YouTube Videos";
      relativePath = "_Videos/_YouTube";
      folderIdPrefix = cfg.youtubeFolderIdPrefix or "nixhomeserver-youtube-videos";
      suggestedDevicePath = "Movies/NixHomeServer/YouTube";
    }
    {
      key = "other";
      label = "Other Videos";
      relativePath = "_Videos/_Other";
      folderIdPrefix = cfg.otherFolderIdPrefix or "nixhomeserver-other-videos";
      suggestedDevicePath = "Movies/NixHomeServer/Other";
    }
  ];
  folderSpecsRaw = cfg.folders or defaultFolderSpecs;
  folderSpecsAreList = builtins.isList folderSpecsRaw;
  rawSpecs = if folderSpecsAreList then folderSpecsRaw else [ ];
  normaliseSpec = index: raw:
    let
      spec = if builtins.isAttrs raw then raw else { };
      fallback = "invalid-offline-media-folder-${toString (index + 1)}";
      relativePath = if builtins.isString (spec.relativePath or null) then spec.relativePath else fallback;
      folderIdPrefix = if builtins.isString (spec.folderIdPrefix or null) then spec.folderIdPrefix else fallback;
    in
    spec // {
      inherit relativePath folderIdPrefix;
      key = if builtins.isString (spec.key or null) then spec.key else "folder-${toString (index + 1)}";
      label = if builtins.isString (spec.label or null) then spec.label else relativePath;
      suggestedDevicePath =
        if builtins.isString (spec.suggestedDevicePath or null) then
          spec.suggestedDevicePath
        else
          relativePath;
    };
  folderSpecs = lib.imap0 normaliseSpec rawSpecs;
  invalidFolderSpecIndexes = map
    (index: index + 1)
    (lib.filter
      (index:
        let raw = builtins.elemAt rawSpecs index;
        in
        !(builtins.isAttrs raw)
        || !(builtins.isString (raw.relativePath or null))
        || !(builtins.isString (raw.folderIdPrefix or null)))
      (lib.range 0 ((builtins.length rawSpecs) - 1)));
  validFolderIdPrefix = prefix:
    builtins.isString prefix
    && builtins.stringLength prefix >= 1
    && builtins.stringLength prefix <= 64
    && builtins.match "[a-z][a-z0-9._-]*" prefix != null;
  invalidFolderIdPrefixes = map (spec: spec.folderIdPrefix)
    (lib.filter (spec: !validFolderIdPrefix spec.folderIdPrefix) folderSpecs);
  folderIdPrefixes = map (spec: spec.folderIdPrefix) folderSpecs;
  relativePaths = map (spec: spec.relativePath) folderSpecs;
in
{
  inherit
    folderSpecs
    folderSpecsAreList
    invalidFolderIdPrefixes
    invalidFolderSpecIndexes
    musicFolderName
    relativePaths
    ;
  duplicateFolderIdPrefixes =
    builtins.length folderIdPrefixes != builtins.length (lib.unique folderIdPrefixes);
  duplicateRelativePaths =
    builtins.length relativePaths != builtins.length (lib.unique relativePaths);
}
