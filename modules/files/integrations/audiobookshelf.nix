{ lib, vars, ... }:

{
  users.users.filestash.extraGroups = lib.mkAfter [ "audiobookshelf-media" ];
}
