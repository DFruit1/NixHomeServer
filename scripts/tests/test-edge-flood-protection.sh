#!/usr/bin/env bash

# Edge flood containment must bound per-connection and per-client work without
# ever keying on a client-supplied header. The identity vhost is reached both
# from the internet through the Cloudflare tunnel (which makes every request look
# like it came from loopback to Caddy) and directly from the LAN/NetBird. A
# per-client HTTP-layer limiter would therefore need a trusted client IP, and
# pinning one would mean trusting CF-Connecting-IP or X-Forwarded-For from a
# path a LAN client can reach directly. So the Caddy-side controls stay keyed on
# the real socket peer and the connection lifecycle, and the only genuinely
# per-client limit is placed at the resolver, where the peer address comes from
# the network layer and cannot be spoofed by a header.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools nix jq

host="$(test_default_host)"

evaluated="$(NIXHOMESERVER_TEST_HOST="$host" flake_eval_json '
  hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  base = builtins.getAttr hostName f.nixosConfigurations;
  cfg = base.config;

  disabled = (base.extendModules {
    modules = [{
      repo.caddy.edgeProtection.enable = lib.mkForce false;
      repo.unbound.floodProtection.enable = lib.mkForce false;
    }];
  }).config;

  invalidLimit = (base.extendModules {
    modules = [{ repo.unbound.floodProtection.ipRateLimit = 0; }];
  }).config;
  invalidFactor = (base.extendModules {
    modules = [{ repo.unbound.floodProtection.ipRateLimitFactor = 0; }];
  }).config;
  invalidTcp = (base.extendModules {
    modules = [{ repo.caddy.edgeProtection.upstreamMaxConnsPerHost = 0; }];
  }).config;
  invalidHeaderSize = (base.extendModules {
    modules = [{ repo.caddy.edgeProtection.maxHeaderSize = "16384"; }];
  }).config;

  vars = import ./vars.nix { inherit lib; };
in {
  caddyCfg = cfg.repo.caddy.edgeProtection;
  caddyGlobal = cfg.services.caddy.globalConfig;
  kanidmVhost = cfg.services.caddy.virtualHosts.${vars.kanidmDomain}.extraConfig;
  unboundServer = cfg.services.unbound.settings.server;
  floodCfg = cfg.repo.unbound.floodProtection;

  disabledCaddyGlobal = disabled.services.caddy.globalConfig;
  disabledKanidm = disabled.services.caddy.virtualHosts.${vars.kanidmDomain}.extraConfig;
  disabledUnboundServer = disabled.services.unbound.settings.server;

  invalidMessages = lib.concatLists [
    (map (entry: entry.message) (builtins.filter (entry: !entry.assertion) invalidLimit.assertions))
    (map (entry: entry.message) (builtins.filter (entry: !entry.assertion) invalidFactor.assertions))
    (map (entry: entry.message) (builtins.filter (entry: !entry.assertion) invalidTcp.assertions))
    (map (entry: entry.message) (builtins.filter (entry: !entry.assertion) invalidHeaderSize.assertions))
  ];
}')"

# The Caddy controls must be present and real, not just declared.
jq -e '
  (.caddyCfg.enable == true)
  and (.caddyCfg.readHeaderTimeout == "10s")
  and (.caddyCfg.idleTimeout == "2m")
  and (.caddyCfg.maxHeaderSize == "16KiB")
  and (.caddyCfg.maxRequestBodySize == "2MB")
  and (.caddyCfg.upstreamMaxConnsPerHost == 512)
  and (.caddyCfg.upstreamIdleConnsPerHost == 64)
  and (.caddyGlobal | contains("servers {"))
  and (.caddyGlobal | contains("read_header 10s"))
  and (.caddyGlobal | contains("idle 2m"))
  and (.caddyGlobal | contains("max_header_size 16KiB"))
  # The identity vhost carries the body ceiling and the upstream pool bounds.
  and (.kanidmVhost | contains("request_body {"))
  and (.kanidmVhost | contains("max_size 2MB"))
  and (.kanidmVhost | contains("max_conns_per_host 512"))
  and (.kanidmVhost | contains("keepalive_idle_conns_per_host 64"))
  # Normal auth traffic must still be proxied to the identity backend.
  and (.kanidmVhost | contains("tls_server_name"))
  and (.kanidmVhost | contains("X-Forwarded-Proto https"))
' <<<"$evaluated" >/dev/null || {
  echo "❌ Caddy edge protection is not rendering per-server resource bounds."
  jq '.caddyCfg, .caddyGlobal' <<<"$evaluated"
  exit 1
}

# Spoofed client-identity headers must not appear anywhere in the generated
# configuration. Trusting CF-Connecting-IP or X-Forwarded-For without a pinned
# trusted-proxy range would let any LAN client forge an identity, so assert the
# trust directives stay absent rather than trusting the source template.
jq -e '
  ([.caddyGlobal, .kanidmVhost, .unboundServer]
    | [.[] | .. | strings]
    | map(select((contains("trusted_proxies")) or (contains("client_ip_headers"))))
    | length) == 0
' <<<"$evaluated" >/dev/null || {
  echo "❌ A client-identity trust directive leaked into the evaluated edge configuration."
  exit 1
}

# The resolver limits are the only genuinely per-client control, and they must
# key on the real socket peer for the exact client networks this host serves.
jq -e '
  (.floodCfg.enable == true)
  and (.unboundServer | ."ip-ratelimit" == 300)
  and (.unboundServer | ."ip-ratelimit-factor" == 10)
  and (.unboundServer | ."ip-ratelimit-cookie" == 60)
  and (.unboundServer | ."use-caps-for-id" == true)
  and (.unboundServer | ."incoming-num-tcp" == 16)
  and (.unboundServer | ."outgoing-num-tcp" == 16)
  and (.unboundServer | ."tcp-connection-limit" | length == 3)
  and (.unboundServer | ."tcp-connection-limit" | all(.[];
    test("^[0-9./]+ [1-9][0-9]*$")))
  # Loopback must be bounded too: cloudflared reaches the origin from loopback,
  # so an unbounded tunnel origin would defeat the limit.
  and (.unboundServer | ."tcp-connection-limit" | any(.[]; contains("127.0.0.0/8")))
  and (.unboundServer | ."tcp-connection-limit" | any(.[]; test("^100\\.64\\.")))
  # Pre-existing hardening must survive alongside the new limits.
  and (.unboundServer | ."private-address" | length >= 6)
  and (.unboundServer | ."hide-identity" == true)
  and (.unboundServer | ."ip-freebind" == true)
' <<<"$evaluated" >/dev/null || {
  echo "❌ Unbound per-client flood limits are missing or malformed."
  jq '.floodCfg, .unboundServer' <<<"$evaluated"
  exit 1
}

# Disabling must actually remove the rendered directives rather than leaving
# stale config behind.
jq -e '
  ((.disabledCaddyGlobal | contains("read_header")) | not)
  and ((.disabledCaddyGlobal | contains("max_header_size")) | not)
  and ((.disabledKanidm | contains("request_body")) | not)
  and ((.disabledKanidm | contains("max_conns_per_host")) | not)
  and ((.disabledKanidm | contains("keepalive_idle_conns_per_host")) | not)
  and ((.disabledUnboundServer | ."ip-ratelimit") == null)
  and ((.disabledUnboundServer | ."tcp-connection-limit") == null)
  and ((.disabledUnboundServer | ."use-caps-for-id") == null)
  # Disabling flood protection must not remove unrelated resolver hardening.
  and (.disabledUnboundServer | ."private-address" | length >= 6)
  and (.disabledUnboundServer | ."ip-freebind" == true)
' <<<"$evaluated" >/dev/null || {
  echo "❌ Disabling edge/flood protection left rendered directives behind."
  jq '.disabledCaddyGlobal, .disabledUnboundServer' <<<"$evaluated"
  exit 1
}

# A zero or unit-less value must fail evaluation with an actionable message
# rather than silently removing the control.
jq -e '
  (.invalidMessages | length >= 4)
  and (.invalidMessages | any(contains("ipRateLimit must be greater than zero")))
  and (.invalidMessages | any(contains("ipRateLimitFactor is a percentage")))
  and (.invalidMessages | any(contains("upstreamMaxConnsPerHost")))
  and (.invalidMessages | any(contains("maxHeaderSize must be a Caddy byte size")))
' <<<"$evaluated" >/dev/null || {
  echo "❌ Invalid edge/flood protection values are not rejected in evaluation."
  jq '.invalidMessages' <<<"$evaluated"
  exit 1
}

echo "✅ Edge flood containment bounds per-connection and per-resolver-client work without trusting client-supplied identity headers."