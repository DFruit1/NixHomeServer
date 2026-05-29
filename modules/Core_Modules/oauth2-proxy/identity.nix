{ ... }:

{
  users.groups.oauth2-proxy = { };

  users.users.oauth2-proxy = {
    isSystemUser = true;
    group = "oauth2-proxy";
    home = "/var/empty";
  };
}
