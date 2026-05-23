{ lib, ... }:

{
  users.users.filestash.extraGroups = lib.mkAfter [ "jellyfin-media" ];
}
