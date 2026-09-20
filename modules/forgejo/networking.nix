{ config, lib, vars, ... }:

let
  cfg = config.repo.forgejo;
  loopback = vars.networking.loopbackIPv4;
  lanIface = vars.networking.interfaces.lan;
  netbirdIface = vars.networking.interfaces.netbird;
  host = "git.${vars.domain}";
in
{
  config = lib.mkIf cfg.enable {
    services.caddy.virtualHosts.${host} = {
      logFormat = null;
      useACMEHost = vars.domain;
      extraConfig = ''
        reverse_proxy http://${loopback}:${toString vars.networking.ports.forgejo} {
          header_up X-Forwarded-Proto https
        }
      '';
    };

    services.unbound.privateHosts.${host} = {
      target = "private";
    };

    # Git over SSH is exposed only on the private LAN and NetBird meshes; the
    # Forgejo built-in SSH server listens on all interfaces and the host
    # firewall scopes it to those two.
    networking.firewall.interfaces = {
      ${lanIface}.allowedTCPPorts = [ vars.networking.ports.forgejoSsh ];
      ${netbirdIface}.allowedTCPPorts = [ vars.networking.ports.forgejoSsh ];
    };
  };
}
