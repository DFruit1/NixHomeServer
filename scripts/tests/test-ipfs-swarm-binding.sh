#!/usr/bin/env bash

# Kubo's swarm listener must be bound to the NetBird address it advertises,
# rather than to a wildcard address that the firewall happens to mitigate.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

host="$(test_default_host)"

kubo_json="$(NIXHOMESERVER_TEST_HOST="$host" flake_eval_json '
  hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  settings = f.lib.nixhomeserverSettings.${hostName};
  cfg = (builtins.getAttr hostName f.nixosConfigurations).config;
  netbirdIp = settings.networking.netbird.ip;
  loopback = settings.networking.loopbackIPv4;
  swarmPort = settings.networking.ports.ipfsSwarm;
  gatewayPort = settings.networking.ports.ipfsGateway;
  aliasPort = settings.networking.ports.ipfsAlias;
in {
  registered = cfg.nixhomeserver.modules.ipfs or false;
  netbirdIp = netbirdIp;
  swarmAddr = "/ip4/${netbirdIp}/tcp/${toString swarmPort}";
  swarm = cfg.services.kubo.settings.Addresses.Swarm;
  announce = cfg.services.kubo.settings.Addresses.Announce;
  api = cfg.services.kubo.settings.Addresses.API;
  gateway = cfg.services.kubo.settings.Addresses.Gateway;
  bootstrap = cfg.services.kubo.settings.Bootstrap;
  mdns = cfg.services.kubo.settings.Discovery.MDNS.Enabled;
  swarmWildcards = cfg.services.kubo.settings.Addresses.Swarm
    ++ cfg.services.kubo.settings.Addresses.Announce
    ++ [ cfg.services.kubo.settings.Addresses.Gateway ];
  ipfsWants = cfg.systemd.services.ipfs.wants;
  ipfsAfter = cfg.systemd.services.ipfs.after;
  # The generated unit text is what systemd actually runs, so the restart
  # policy and ordering are asserted there rather than only in the source.
  ipfsUnit = cfg.systemd.units."ipfs.service".text or "";
  netbirdVerifyRequires =
    cfg.systemd.services.netbird-address-verify.requires;
  gatewayListenStreams = cfg.systemd.sockets.ipfs-gateway.socketConfig.ListenStream;
  apiListenStreams = cfg.systemd.sockets.ipfs-api.socketConfig.ListenStream;
  netbirdFirewallPorts =
    cfg.networking.firewall.interfaces.${settings.networking.interfaces.netbird}.allowedTCPPorts;
  lanFirewallPorts =
    cfg.networking.firewall.interfaces.${settings.networking.interfaces.lan}.allowedTCPPorts or [];
  caddyIpfsHost = cfg.services.caddy.virtualHosts ? "ipfs.${settings.domain}";
  privateIpfsHost = cfg.services.unbound.privateHosts ? "ipfs.${settings.domain}";
  aliasListen = cfg.systemd.services.ipfs-alias.environment.IPFS_ALIAS_LISTEN;
  aliasChannelsDir = cfg.systemd.services.ipfs-alias.environment.IPFS_ALIAS_CHANNELS_DIR;
  expected = {
    swarmAddr = "/ip4/${netbirdIp}/tcp/${toString swarmPort}";
    gateway = "/ip4/${loopback}/tcp/${toString gatewayPort}";
    gatewayListenStream = "${loopback}:${toString gatewayPort}";
    aliasListen = "${loopback}:${toString aliasPort}";
    swarmPort = swarmPort;
  };
}')"

if [[ "$(jq -e 'type == "object"' <<<"$kubo_json" >/dev/null; echo $?)" != 0 ]]; then
  echo "❌ Evaluated Kubo configuration is not an object." >&2
  jq . <<<"$kubo_json" >&2
  exit 1
fi

swarm_port="$(jq -r '.expected.swarmPort' <<<"$kubo_json")"

jq -e --argjson swarmPort "$swarm_port" '
  # The swarm listener and the announced address are the same non-wildcard
  # NetBird multiaddr, so nothing else is reachable on the peer port.
  .registered == true
  and .swarm == [ .expected.swarmAddr ]
  and .announce == [ .expected.swarmAddr ]
  and ([ .swarmWildcards[] ] | all((contains("/ip4/0.0.0.0/") | not)))
  # The gateway, control API and published listeners are untouched by binding.
  and .gateway == .expected.gateway
  and .api == []
  and (.gatewayListenStreams | length == 2)
  and (.gatewayListenStreams[0] == "")
  and (.gatewayListenStreams[1] == .expected.gatewayListenStream)
  and .apiListenStreams == [ "", "%t/ipfs.sock" ]
  and .aliasListen == .expected.aliasListen
  and (.aliasChannelsDir | endswith("/ipfs-distribution/channels"))
  # Content routing stays disabled and the overlay-only peer port scoping is
  # unchanged: open on NetBird, never on the LAN interface.
  and .bootstrap == []
  and .mdns == false
  and (.netbirdFirewallPorts | index($swarmPort) != null)
  and (.lanFirewallPorts | index($swarmPort) == null)
  # Publication path and private DNS/Caddy surfaces are untouched.
  and .caddyIpfsHost == true
  and .privateIpfsHost == true
  # Address availability: the daemon waits for the unit that actually proves
  # the overlay address exists (it requires both the client and the enrollment
  # helper, then polls nb0 until it matches vars.nix), not merely for the
  # client daemon. `wants`/`after` keep it a soft dependency, so a broken
  # overlay delays the gateway rather than blocking it permanently.
  and (.netbirdVerifyRequires | index("netbird-main-login.service") != null)
  and (.netbirdVerifyRequires | index("netbird-main.service") != null)
  and (.ipfsWants | index("netbird-address-verify.service") != null)
  and (.ipfsAfter | index("netbird-address-verify.service") != null)
  # Asserted against the generated unit, because that is what systemd runs:
  # a source-level restart policy that never reaches the unit would leave
  # Kubo permanently failed whenever the bind loses the race with NetBird.
  and (.ipfsUnit | test("(?m)^Restart=on-failure$"))
  and (.ipfsUnit | test("(?m)^RestartSec=[0-9]+s$"))
  # Unbounded start retries: a late address must not exhaust the burst limit.
  and (.ipfsUnit | test("(?m)^StartLimitIntervalSec=0$"))
  # The retry must not have clobbered how the daemon is actually launched.
  and (.ipfsUnit | test("(?m)^ExecStart=.*ipfs daemon"))
  and (.ipfsUnit | test("(?m)^ExecStartPre="))
  and (.ipfsUnit | test("(?m)^Sockets=ipfs-gateway[.]socket$"))
  and (.ipfsUnit | test("(?m)^Sockets=ipfs-api[.]socket$"))
' <<<"$kubo_json" >/dev/null || {
  echo "❌ Kubo swarm binding, listeners, firewall scoping, NetBird ordering, or the bind retry policy regressed." >&2
  jq . <<<"$kubo_json" >&2
  exit 1
}

forbid_match modules/ipfs/services.nix '/ip4/0[.]0[.]0[.]0' \
  "Kubo must not fall back to a wildcard listener."
require_fixed modules/ipfs/services.nix 'Swarm = [ swarmAddr ];' \
  "The swarm listener must be the shared NetBird swarm multiaddr."
require_fixed modules/ipfs/services.nix 'Announce = [ swarmAddr ];' \
  "The advertised address must be the multiaddr the daemon binds."
require_fixed modules/ipfs/networking.nix \
  'networking.firewall.interfaces.${vars.networking.interfaces.netbird}.allowedTCPPorts = [ swarmPort ];' \
  "The NetBird interface must remain the only place the swarm port is opened."

swarm_addr="$(jq -r '.swarmAddr' <<<"$kubo_json")"
echo "✅ IPFS swarm binding tests passed (bound to ${swarm_addr})."
