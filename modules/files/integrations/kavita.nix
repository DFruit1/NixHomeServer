{ lib, vars, ... }:

{
  users.users.filestash.extraGroups = lib.mkAfter [ "kavita-media" ];
}
