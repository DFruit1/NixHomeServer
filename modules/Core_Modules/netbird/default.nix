{ lib, config, pkgs, vars, ... }:

let
  netbirdIface = vars.networking.interfaces.netbird;
  wgPort = vars.networking.ports.netbirdWireGuard;
in
{
  imports = [
    ./bootstrap.nix
  ];

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
  systemd.services."netbird-main" = {
    wants = [ "network-online.target" "unbound.service" ];
    after = [ "network-online.target" "unbound.service" ];
  };

  systemd.services."netbird-main-login" = {
    wants = [ "unbound.service" ];
    after = [ "unbound.service" ];
  };

  # The upstream login helper matches "Disconnected" as if it were "Connected"
  # and exits before it ever runs `netbird up --setup-key-file=...`.
  systemd.services."netbird-main-login".script = lib.mkForce ''
    set -euo pipefail
    netbird_bin="''${NETBIRD_LOGIN_NETBIRD_BIN:-/run/current-system/sw/bin/netbird-main}"
    setup_key_file="''${NETBIRD_LOGIN_SETUP_KEY_FILE:-${config.age.secrets.netbirdSetupKey.path}}"
    status_attempts="''${NETBIRD_LOGIN_STATUS_ATTEMPTS:-60}"
    status_delay="''${NETBIRD_LOGIN_STATUS_DELAY_SECONDS:-1}"
    status_output=""
    status_rc=0

    if [[ ! "$status_attempts" =~ ^[1-9][0-9]*$ ]]; then
      echo "NetBird login helper received an invalid status-attempt limit: $status_attempts" >&2
      exit 2
    fi
    if [[ ! "$status_delay" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      echo "NetBird login helper received an invalid status delay: $status_delay" >&2
      exit 2
    fi

    refresh_status() {
      if status_output="$("$netbird_bin" status 2>&1)"; then
        status_rc=0
      else
        status_rc=$?
      fi
    }

    is_connected() {
      grep -q '^Management: Connected$' <<<"$status_output"
    }

    needs_login() {
      grep -q 'NeedsLogin' <<<"$status_output"
    }

    main() {
      local attempt up_rc
      for ((attempt = 1; attempt <= status_attempts; attempt++)); do
        refresh_status

        if is_connected; then
          echo "NetBird management connection is already established."
          return 0
        fi
        if needs_login; then
          echo "NetBird requests enrollment; applying the configured setup key."
          if "$netbird_bin" up --setup-key-file="$setup_key_file"; then
            echo "NetBird enrollment command completed successfully."
            return 0
          else
            up_rc=$?
          fi
          echo "NetBird enrollment failed with exit status $up_rc; systemd will retry this helper." >&2
          return "$up_rc"
        fi

        if ((attempt < status_attempts)); then
          echo "Waiting for NetBird status to become usable (attempt $attempt/$status_attempts, status exit $status_rc)." >&2
          sleep "$status_delay"
        fi
      done

      echo "NetBird did not become ready after $status_attempts status attempts (last status exit $status_rc)." >&2
      if [[ -n "$status_output" ]]; then
        echo "Last NetBird status output:" >&2
        printf '%s\n' "$status_output" >&2
      fi
      return 1
    }

    main "$@"
  '';

  systemd.services."netbird-main-login".serviceConfig = {
    Restart = "on-failure";
    RestartSec = "10s";
    TimeoutStartSec = "2min";
  };

  systemd.services.netbird-address-verify = {
    description = "Verify the enrolled NetBird address matches vars.nix";
    wantedBy = [ "multi-user.target" ];
    requires = [ "netbird-main.service" "netbird-main-login.service" ];
    after = [ "netbird-main.service" "netbird-main-login.service" ];
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = "10s";
      TimeoutStartSec = "3min";
    };
    path = [ pkgs.coreutils pkgs.gawk pkgs.iproute2 ];
    script = ''
      set -euo pipefail

      expected=${lib.escapeShellArg vars.networking.netbird.ip}
      interface=${lib.escapeShellArg netbirdIface}
      actual=""
      for _ in $(seq 1 120); do
        actual="$(ip -4 -o address show dev "$interface" 2>/dev/null \
          | awk '{ sub(/\/.*/, "", $4); print $4; exit }')"
        if [[ "$actual" == "$expected" ]]; then
          exit 0
        fi
        sleep 1
      done

      echo "NetBird assigned '$actual' on $interface, but vars.nix expects '$expected'. Update network.netbirdIp (and the NetBird peer assignment if supported), then redeploy over LAN." >&2
      exit 1
    '';
  };
}
