{ config, lib, vars, ... }:

# Groundwater alerts and logger events reach phones through the private ntfy
# server. The server publishes to ntfy's loopback listener only: ntfy topics
# are unauthenticated, and a message names the device and its location. A
# subscriber needs LAN or NetBird access to ntfy's private hostname.
{
  config = lib.mkIf (config.repo.groundwaterLogger.enable && config.repo.ntfy.enable) {
    repo.groundwaterLogger.notifications.ntfyUrl = lib.mkDefault
      "http://${vars.networking.loopbackIPv4}:${toString config.repo.ntfy.port}/groundwater";

    # Notifications are best effort: ntfy being down must never hold back
    # the groundwater server, so this is ordering only, not a dependency.
    systemd.services.groundwater-server.after = [ "ntfy.service" ];
  };
}
