{ lib, ... }:

{
  users.users.filestash.extraGroups = lib.mkAfter [ "kavita-media" ];
}
