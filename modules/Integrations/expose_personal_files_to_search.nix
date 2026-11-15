{ config, lib, options, vars, ... }:

let
  searchPresent = lib.hasAttrByPath [ "repo" "search" ] options;
  filesPresent = lib.hasAttrByPath [ "repo" "files" ] options;
  transcribePresent = lib.hasAttrByPath [ "repo" "transcribe" ] options;
in
{
  # As in the Media Manager integration, the structure of this config is
  # decided from `options` alone and the runtime flag is applied with mkIf.
  config = lib.optionalAttrs
    (searchPresent && (filesPresent || transcribePresent))
    (lib.mkIf config.repo.search.enable {
      # Each person's own documents and finished transcripts. Only document
      # formats are read, and results carry their owner, as archived mail does.
      repo.search.sources.files = {
        displayName = "Personal files";
        sourceType = "files";
        appBase = "https://files.${vars.domain}";
        settings = {
          usersRoot = vars.usersRoot;
        }
        // lib.optionalAttrs filesPresent { documentDirs = [ "_Files" ]; }
        // lib.optionalAttrs transcribePresent { transcriptDirs = [ "_Transcripts" ]; };
      };

      repo.storage.userRoots = {
        rootTraverseGroups = [ "search" ];
        # Read-only, and only the folders indexed above. Transcripts are
        # otherwise readable by the Media Manager group alone.
        recursiveReadonlyGrants = [
          {
            group = "search";
            relativePaths =
              lib.optional filesPresent "_Files"
              ++ lib.optional transcribePresent "_Transcripts";
          }
        ];
      };
    });
}
