#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

host="$(test_default_host)"

# A single evaluation answers every question: the clean host, each variant that
# tries to publish SearXNG, and the disabled host. Nix shares nothing between
# processes, so three separate queries would cost three module-system builds.
searxng_json="$(NIXHOMESERVER_TEST_HOST="$host" flake_eval_json '
  host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  base = builtins.getAttr host f.nixosConfigurations;
  vars = f.lib.nixhomeserverSettings.${host};
  cfg = base.config;

  messages = extended: map (entry: entry.message)
    (builtins.filter (entry: !entry.assertion) extended.assertions);
  firesOn = modules: messages (base.extendModules { inherit modules; }).config;

  # A raw Caddy vhost reverse-proxying the loopback port, written in several
  # spellings that all resolve to the same origin.
  caddyPublish = extraConfig: [{
    services.caddy.virtualHosts."searx.${vars.domain}" = {
      useACMEHost = vars.domain;
      inherit extraConfig;
    };
  }];
  gatewayPublish = upstream: [{
    repo.authGateway.protectedApps.searx = {
      host = "searx.${vars.domain}";
      inherit upstream;
      allowedGroups = [ "searxng-users" ];
    };
  }];
  routePublish = [{
    repo.authGateway.protectedApps.aiTools.authenticatedRoutes = [{
      pathPrefix = "/search";
      upstream = "http://127.0.0.1:${toString vars.networking.ports.searxng}";
    }];
  }];
  driftedPort = [{
    repo.searxng.port = 9199;
  }];

  service = cfg.systemd.services.searxng;
  catalog = import ./modules/catalog.nix;
in {
  domain = vars.domain;
  registered = cfg.nixhomeserver.modules.searxng or false;
  enabled = cfg.repo.searxng.enable;

  # Port ownership: searxng owns its own port, ai-tools owns only its own.
  searxngRegistration = catalog.apps.searxng.registration.ports;
  aiToolsRegistration = catalog.apps.ai-tools.registration.ports;
  registeredPort = vars.networking.ports.searxng or null;
  aiToolsPort = vars.networking.ports.aiTools or null;
  portMatchesOption = cfg.repo.searxng.port;

  # The loopback bind and the settings derivation must survive untouched.
  settings = builtins.readFile cfg.repo.searxng.settingsFile;
  homepageEntry = (catalog.apps.searxng.registration.homepage { inherit cfg vars; });

  # Ordering and resource containment.
  after = service.after;
  wants = service.wants;
  cpuWeight = service.serviceConfig.CPUWeight or null;
  nice = service.serviceConfig.Nice or null;
  ioWeight = service.serviceConfig.IOWeight or null;
  execStart = service.serviceConfig.ExecStart;
  searxngUser = cfg.users.users.searxng.isSystemUser;

  # A legitimate ai-tools upstream on its own port must not trip the invariant.
  aiToolsUpstream = cfg.repo.authGateway.protectedApps.aiTools.upstream;

  caddyVariants = {
    plain = firesOn (caddyPublish "reverse_proxy http://127.0.0.1:8098");
    upperScheme = firesOn (caddyPublish "reverse_proxy HTTP://127.0.0.1:8098");
    trailingPath = firesOn (caddyPublish "reverse_proxy http://127.0.0.1:8098/search");
    userinfo = firesOn (caddyPublish "reverse_proxy http://caddy:127.0.0.1@127.0.0.1:8098");
    ipv6Loopback = firesOn (caddyPublish "reverse_proxy http://[::1]:8098");
  };
  gatewayUpstream = firesOn (gatewayPublish "http://127.0.0.1:8098");
  authenticatedRoute = firesOn routePublish;
  portDrift = firesOn driftedPort;

  # A neighbouring port on the same host is not SearXNG and must stay allowed.
  unrelatedPort = firesOn (caddyPublish "reverse_proxy http://127.0.0.1:8097");
}')"

jq -e '
  .registered
  and .enabled
  and (.registeredPort == 8098)
  and (.portMatchesOption == 8098)
  and (.searxngRegistration == { searxng: 8098 })
  and (.aiToolsRegistration == { aiTools: 8097 })
  and (.aiToolsPort == 8097)
  and (.homepageEntry == [])
  and (.settings | contains("bind_address: \"127.0.0.1\""))
  and (.settings | contains("port: 8098"))
  and (.settings | contains("secret_key: \"generated-per-boot-not-used-for-public-listen\""))
  and (.settings | contains("formats:\n    - html\n    - json"))
  and (.execStart | endswith("/bin/searxng-run"))
  and (.searxngUser == true)
  and (.cpuWeight == 20)
  and (.nice == 10)
  and (.ioWeight == 20)
  and (.after | index("systemd-sysusers.service") != null)
  and (.wants | index("network-online.target") != null)
  and (.aiToolsUpstream == "http://127.0.0.1:8097")
' <<<"$searxng_json" >/dev/null || {
  echo "❌ SearXNG must own its own port registration, keep the loopback bind, and run the shipped searxng-run binary."
  jq . <<<"$searxng_json"
  exit 1
}

# Every spelling of a loopback:8098 target must trip the invariant, and each
# message must name the offending target so the fix is obvious.
for variant in plain upperScheme trailingPath userinfo ipv6Loopback; do
  offenders="$(jq -r --arg variant "$variant" '.caddyVariants[$variant] | map(select(contains("127.0.0.1:8098") or contains("[::1]:8098"))) | length' <<<"$searxng_json")"
  if [[ "$offenders" -ne 1 ]]; then
    echo "❌ A Caddy vhost proxying loopback:8098 as '${variant}' must be rejected, naming the target."
    jq '.caddyVariants' <<<"$searxng_json"
    exit 1
  fi
  if ! jq -e --arg variant "$variant" '.caddyVariants[$variant] | map(select(contains("must never be published through the gateway"))) | length == 1' <<<"$searxng_json" >/dev/null; then
    echo "❌ The SearXNG publication invariant must report the '${variant}' target it rejected."
    jq '.caddyVariants' <<<"$searxng_json"
    exit 1
  fi
done

# The gateway's own upstream and sub-route surfaces must be covered too.
for surface in gatewayUpstream authenticatedRoute; do
  if ! jq -e --arg surface "$surface" '
    .[$surface] as $hits
    | ($hits | length) == 1 and ($hits[0] | contains("must never be published through the gateway"))
  ' <<<"$searxng_json" >/dev/null; then
    echo "❌ The SearXNG publication invariant must also cover ${surface}."
    jq --arg surface "$surface" '.[$surface]' <<<"$searxng_json"
    exit 1
  fi
done

# A drifted port option must fail loudly rather than serve somewhere the
# registration and the ai-tools client disagree about.
if ! jq -e '
    .portDrift as $hits
    | ($hits | length) == 1 and ($hits[0] | contains("modules/searxng/registration.nix"))
  ' <<<"$searxng_json" >/dev/null; then
  echo "❌ repo.searxng.port must be pinned to the registered searxng port."
  jq '.portDrift' <<<"$searxng_json"
  exit 1
fi

# The invariant must not fire on a neighbouring loopback service.
if [[ "$(jq -r '.unrelatedPort | length' <<<"$searxng_json")" -ne 0 ]]; then
  echo "❌ The SearXNG invariant must match the parsed port, not merely the loopback host."
  jq '.unrelatedPort' <<<"$searxng_json"
  exit 1
fi

echo "✅ SearXNG loopback-only invariant and port ownership tests passed."