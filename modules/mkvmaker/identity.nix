{ ... }:

{
  users.groups.mkvmaker = { };

  users.users.mkvmaker = {
    isSystemUser = true;
    group = "mkvmaker";
    extraGroups = [ "nixhomeserver-maintenance" ];
    home = "/var/lib/mkvmaker";
    createHome = true;
  };
}
