{ lib, config, vars, ... }:

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
    openFirewall = true;
    interface = vars.netbirdIface;
    port = vars.wgPort;
    login.enable = true;
    login.setupKeyFile = config.age.secrets.netbirdSetupKey.path;
  };

  networking.firewall.allowedUDPPorts = [ vars.wgPort ];

  systemd.services."netbird-main".serviceConfig.AppArmorProfile = "generated-netbird-main";

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
