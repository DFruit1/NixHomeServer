{ lib, ... }:

{
  users.users.filestash.extraGroups = lib.mkAfter [ "audiobookshelf-media" ];
}
