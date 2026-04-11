{ vars, ... }:

{
  services.jellyseerr = {
    enable = true;
    port = vars.jellyseerrPort;
  };
}
