{ lib, config, vars, ... }:

let
  netbirdIface = vars.networking.interfaces.netbird;
  wgPort = vars.networking.ports.netbirdWireGuard;
in
{
  users.groups."netbird-main" = { };

  users.users."netbird-main" = {
    isSystemUser = true;
    group = "netbird-main";
    home = "/var/lib/netbird-main";
  };

  services.netbird.clients.myNetbirdClient = {
    name = "main";
    hardened = true;
    autoStart = true;
    interface = netbirdIface;
    port = wgPort;
    openFirewall = false;
    login.enable = true;
    login.setupKeyFile = config.age.secrets.netbirdSetupKey.path;
  };

  networking.firewall.allowedUDPPorts = [ wgPort ];
  # The upstream login helper matches "Disconnected" as if it were "Connected"
  # and exits before it ever runs `netbird up --setup-key-file=...`.
  systemd.services."netbird-main-login".script = lib.mkForce ''
    set -euo pipefail
    status_file="/tmp/status.txt"
    netbird_bin="/run/current-system/sw/bin/netbird-main"

    refresh_status() {
      "$netbird_bin" status &>"$status_file" || :
    }

    is_connected() {
      grep -q '^Management: Connected$' "$status_file"
    }

    needs_login() {
      grep -q 'NeedsLogin' "$status_file"
    }

    main() {
      until refresh_status && { is_connected || needs_login; }; do
        sleep 1
      done

      if ! is_connected; then
        "$netbird_bin" up --setup-key-file="${config.age.secrets.netbirdSetupKey.path}"
      fi
    }

    main "$@"
  '';
}
