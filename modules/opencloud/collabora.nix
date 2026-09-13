{ vars, ... }:

let
  cloudHost = "cloud.${vars.domain}";
  officeHost = "office.${vars.domain}";
in
{
  services.collabora-online = {
    enable = true;
    port = vars.networking.ports.collaboraOnline;
    aliasGroups = [
      {
        host = "https://${officeHost}";
        aliases = [ "https://${cloudHost}" ];
      }
    ];
    settings = {
      # Allow WOPI traffic and serve plain HTTP to Caddy, which is the only
      # TLS terminator in front of coolwsd.
      storage.wopi."@allow" = true;
      ssl.enable = false;
      ssl.termination = true;
    };
  };

  systemd.services.coolwsd.after = [ "opencloud-storage-layout-v1.service" ];
}
