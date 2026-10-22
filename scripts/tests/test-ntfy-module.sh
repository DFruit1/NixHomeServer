#!/usr/bin/env bash
# ntfy module tests.
#
# The deployment's entire security model is "unauthenticated topics, reachable
# only from the loopback bind through a private Caddy host". These assertions
# are the machine-checked form of that claim, so each one is written to fail
# when the property it names is broken rather than to merely describe intent.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

host="$(test_default_host)"

ntfy_json="$(NIXHOMESERVER_TEST_HOST="$host" flake_eval_json '
  host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  base = builtins.getAttr host f.nixosConfigurations;
  vars = f.lib.nixhomeserverSettings.${host};
  cfg = base.config;
  domain = vars.domain;
  ntfyHost = "ntfy.${domain}";

  # Scoped to the ntfy assertions only. The host assertion set is shared, so an
  # unfiltered list would credit this module with a sibling failure: the
  # "unrelated port" probe deliberately reuses searxng 8098 and trips the searxng
  # publication invariant, which is not an ntfy regression.
  messages = extended: builtins.map (entry: entry.message)
    (builtins.filter
      (entry: !entry.assertion && lib.hasInfix "ntfy" (lib.toLower entry.message))
      extended.assertions);
  firesOn = modules: messages (base.extendModules { inherit modules; }).config;

  # Every spelling of a loopback target that resolves to the same origin.
  caddyPublish = extraConfig: [{
    services.caddy.virtualHosts."rogue.${domain}" = {
      useACMEHost = domain;
      inherit extraConfig;
    };
  }];
  tunnelPublish = [{
    services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress.${ntfyHost} = {
      service = "https://127.0.0.1:443";
      originRequest.originServerName = ntfyHost;
    };
  }];
  gatewayPublish = [{
    repo.authGateway.protectedApps.rogueNtfy = {
      host = "rogue.${domain}";
      upstream = "http://127.0.0.1:8099";
      allowedGroups = [ "ntfy-users" ];
    };
  }];
  driftedPort = [{ repo.ntfy.port = 9199; }];
  wrongPackage = [{ repo.ntfy.package = f.inputs.nixpkgs.legacyPackages.${vars.hostPlatform}.ntfy; }];

  catalog = import ./modules/catalog.nix;
  service = cfg.systemd.services.ntfy;
in {
  domain = domain;
  ntfyHost = ntfyHost;

  registered = cfg.nixhomeserver.modules.ntfy or false;
  enabled = cfg.repo.ntfy.enable;
  inEnabledApps = builtins.elem "ntfy" vars.enabledApps;
  catalogEntry = builtins.attrNames catalog.apps;

  # Loopback-only reach: ntfy binds loopback, Caddy is the only ingress, and
  # Unbound publishes the name on the LAN and the NetBird overlay only.
  port = cfg.repo.ntfy.port;
  registeredPort = vars.networking.ports.ntfy or null;
  registration = catalog.apps.ntfy.registration.ports;
  caddyHost = builtins.hasAttr ntfyHost cfg.services.caddy.virtualHosts;
  caddyBody = cfg.services.caddy.virtualHosts.${ntfyHost}.extraConfig;
  privateHost = cfg.services.unbound.privateHosts.${ntfyHost};
  configFile = builtins.readFile cfg.repo.ntfy.configFile;

  # No Cloudflare ingress and no credential of any kind.
  tunnelIngress = builtins.attrNames cfg.services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress;
  gatewayApps = builtins.attrNames cfg.repo.authGateway.protectedApps;
  # Filtered to the ntfy entries only: the unfiltered lists are every app on the
  # host, so a length test against them would assert the catalog is empty.
  ntfySecrets = builtins.filter (name: lib.hasInfix "ntfy" (lib.toLower name)) (builtins.attrNames cfg.age.secrets);
  # The local ntfy system account is required -- the unit runs as it -- so the
  # absence of a credential is asserted on the Kanidm provisioning surface,
  # which is where an identity boundary would actually be created.
  ntfyUsers = builtins.filter (name: lib.hasInfix "ntfy" name) (builtins.attrNames cfg.users.users);
  kanidmNtfyGroups = builtins.filter (name: lib.hasInfix "ntfy" (lib.toLower name))
    (builtins.attrNames cfg.services.kanidm.provision.groups);
  kanidmNtfyPersons = builtins.filter (name: lib.hasInfix "ntfy" (lib.toLower name))
    (builtins.attrNames cfg.services.kanidm.provision.persons);
  homepageEntry = catalog.apps.ntfy.registration.homepage { cfg = cfg; inherit vars; };

  # Canary exemption carries the documented reason.
  exemptHosts = cfg.repo.canary.coverageExemptHosts;

  # Unit hardening and state.
  execStart = service.serviceConfig.ExecStart;
  serviceUser = service.serviceConfig.User;
  stateDirectory = service.serviceConfig.StateDirectory;
  protectSystem = service.serviceConfig.ProtectSystem;
  memoryMax = service.serviceConfig.MemoryMax;
  cpuWeight = service.serviceConfig.CPUWeight;
  after = service.after;
  guardedServices = cfg.repo.storage.dataPool.guardedServices;
  backupApps = map (entry: entry.app) cfg.repo.backups.appStateEntries;
  persistencePaths = cfg.repo.impermanence.inventory.persistenceDirectories;
  failedAssertions = messages cfg;

  caddyVariants = {
    plain = firesOn (caddyPublish "reverse_proxy http://127.0.0.1:8099");
    upperScheme = firesOn (caddyPublish "reverse_proxy HTTP://127.0.0.1:8099");
    trailingPath = firesOn (caddyPublish "reverse_proxy http://127.0.0.1:8099/mytopic");
    userinfo = firesOn (caddyPublish "reverse_proxy http://caddy:127.0.0.1@127.0.0.1:8099");
    ipv6Loopback = firesOn (caddyPublish "reverse_proxy http://[::1]:8099");
  };
  tunnelRoute = firesOn tunnelPublish;
  gatewayRoute = firesOn gatewayPublish;
  portDrift = firesOn driftedPort;
  wrongPackage = firesOn wrongPackage;
  unrelatedPort = firesOn (caddyPublish "reverse_proxy http://127.0.0.1:8098");
}')"

# The domain is read from the same evaluation rather than re-derived in bash,
# so one Nix process answers every question below.
ntfy_host="$(jq -r '.ntfyHost' <<<"$ntfy_json")"

# The host exists, is enabled, and is reachable only over LAN and NetBird.
jq -e --arg host "$ntfy_host" '
  .registered
  and .enabled
  and (.inEnabledApps)
  and (.catalogEntry | index("ntfy") != null)
  and (.port == 8099)
  and (.registeredPort == 8099)
  and (.registration == { ntfy: 8099 })
  and .caddyHost
  and (.caddyBody | contains("reverse_proxy http://127.0.0.1:8099"))
  and (.privateHost.target == "private")
  and (.privateHost.publishOnLan == true)
  and (.privateHost.publishOnNetbird == true)
  and (.configFile | contains("listen-http: \"127.0.0.1:8099\""))
  # jq does not expand $host inside a string literal, so the expected line is
  # concatenated rather than interpolated.
  and (.configFile | contains(("base-url: " + "\"https://" + $host + "\"")))
' <<<"$ntfy_json" >/dev/null || {
  echo "❌ ntfy must register its own port, bind loopback, and publish a private LAN/NetBird host."
  jq . <<<"$ntfy_json"
  exit 1
}

# The generated config is where the listen address actually lives, so it is
# pinned: unauthenticated topics must never be reachable on a routable address.
if ! jq -e '
    (.configFile | contains("listen-http: \"127.0.0.1:8099\""))
    and ((.configFile | contains("0.0.0.0")) | not)
    and ((.configFile | contains("\nauth-default-access")) | not)
' <<<"$ntfy_json" >/dev/null; then
  echo "❌ The generated ntfy config must bind loopback and must not set auth-default-access."
  jq -r .configFile <<<"$ntfy_json"
  exit 1
fi

# No tunnel route and no gateway app: both would publish unauthenticated topics.
if ! jq -e --arg host "$ntfy_host" '
    (.tunnelIngress | index($host)) == null
    and (.gatewayApps | index("ntfy")) == null
' <<<"$ntfy_json" >/dev/null; then
  echo "❌ ntfy must have no Cloudflare ingress and no auth-gateway app; its topics are unauthenticated."
  jq '{tunnelIngress, gatewayApps}' <<<"$ntfy_json"
  exit 1
fi

# No credential exists to leak: no owned secret, no Kanidm group or account, and
# no Homepage tile. The local system account the unit runs as is required and is
# not a credential.
jq -e '
  (.ntfySecrets | length == 0)
  and ((.kanidmNtfyGroups | length) == 0)
  and ((.kanidmNtfyPersons | length) == 0)
  and ((.ntfyUsers | index("ntfy")) != null)
  and (.serviceUser == "ntfy")
  and ((.homepageEntry | length) == 0)
' <<<"$ntfy_json" >/dev/null || {
  echo "❌ ntfy must own no secret, no Kanidm identity, and no Homepage tile; there is no credential to present."
  jq '{ntfySecrets, kanidmNtfyGroups, kanidmNtfyPersons, ntfyUsers, homepageEntry}' <<<"$ntfy_json"
  exit 1
}

# The canary must be exempted, with the host present in the list so the
# coverage test cannot pass by the host never being registered.
jq -e --arg host "$ntfy_host" '(.exemptHosts | index($host)) != null' <<<"$ntfy_json" >/dev/null || {
  echo "❌ ntfy must be listed under repo.canary.coverageExemptHosts."
  jq .exemptHosts <<<"$ntfy_json"
  exit 1
}

# The unit must run the built server, not the nixpkgs CLI, with the sandbox and
# resource bounds the performance conventions require.
jq -e '
  (.execStart | contains("/bin/ntfy serve -c "))
  and (.execStart | contains("ntfy-server-2.28.0"))
  and (.protectSystem == "strict")
  and (.memoryMax == "512M")
  and (.cpuWeight == 20)
  and (.stateDirectory == "ntfy")
  and (.after | index("systemd-sysusers.service") != null)
  and ((.failedAssertions | length) == 0)
' <<<"$ntfy_json" >/dev/null || {
  echo "❌ The ntfy unit must run the built server under the standard sandbox and resource bounds."
  jq '{execStart, protectSystem, memoryMax, cpuWeight, stateDirectory, after, failedAssertions}' <<<"$ntfy_json"
  exit 1
}

# ntfy holds no shared storage, so it must not be a data-pool consumer and must
# not be backed up; but its state directory must survive a rebuild.
jq -e '
  ((.guardedServices | index("ntfy")) == null)
  and ((.backupApps | index("ntfy")) == null)
  and (.persistencePaths | index("/var/lib/ntfy") != null)
' <<<"$ntfy_json" >/dev/null || {
  echo "❌ ntfy must not depend on the data pool or be backed up, and /var/lib/ntfy must persist."
  jq '{guardedNtfy: (.guardedServices | index("ntfy")), backupApps, persists: (.persistencePaths | index("/var/lib/ntfy"))}' <<<"$ntfy_json"
  exit 1
}

# Every spelling of a loopback:8099 target must trip the publication invariant,
# and the message must name the offending target.
for variant in plain upperScheme trailingPath userinfo ipv6Loopback; do
  offenders="$(jq -r --arg variant "$variant" '.caddyVariants[$variant] | map(select(contains("127.0.0.1:8099") or contains("[::1]:8099"))) | length' <<<"$ntfy_json")"
  if [[ "$offenders" -ne 1 ]]; then
    echo "❌ A Caddy vhost proxying loopback:8099 as '${variant}' must be rejected, naming the target."
    jq '.caddyVariants' <<<"$ntfy_json"
    exit 1
  fi
  if ! jq -e --arg variant "$variant" '.caddyVariants[$variant] | map(select(contains("unauthenticated read-write topics"))) | length == 1' <<<"$ntfy_json" >/dev/null; then
    echo "❌ The ntfy publication invariant must report the '${variant}' target it rejected."
    jq '.caddyVariants' <<<"$ntfy_json"
    exit 1
  fi
done

# A gateway route reaching the loopback port is the same exposure and must fail.
for surface in gatewayRoute tunnelRoute; do
  if ! jq -e --arg surface "$surface" '
    .[$surface] as $hits
    | ($hits | length) >= 1
    and (any($hits[]; contains("unauthenticated") or contains("Cloudflare tunnel")))
  ' <<<"$ntfy_json" >/dev/null; then
    echo "❌ Publishing ntfy through ${surface} must be rejected."
    jq --arg surface "$surface" '.[$surface]' <<<"$ntfy_json"
    exit 1
  fi
done

# A drifted port option must fail loudly rather than serve somewhere the
# registration and the Caddy vhost disagree about.
if ! jq -e '
    .portDrift as $hits
    | ($hits | length) == 1 and ($hits[0] | contains("modules/ntfy/registration.nix"))
  ' <<<"$ntfy_json" >/dev/null; then
  echo "❌ repo.ntfy.port must be pinned to the registered ntfy port."
  jq '.portDrift' <<<"$ntfy_json"
  exit 1
fi

# Pointing the module at the nixpkgs CLI must fail rather than start a client
# that exits immediately.
if ! jq -e '
    .wrongPackage as $hits
    | ($hits | length) == 1 and ($hits[0] | contains("dschep CLI"))
  ' <<<"$ntfy_json" >/dev/null; then
  echo "❌ repo.ntfy.package must reject pkgs.ntfy, which is not a server."
  jq '.wrongPackage' <<<"$ntfy_json"
  exit 1
fi

# The invariant must match the parsed port, not merely the loopback host, so a
# neighbouring loopback service stays publishable.
if [[ "$(jq -r '.unrelatedPort | length' <<<"$ntfy_json")" -ne 0 ]]; then
  echo "❌ The ntfy invariant must match the parsed port, not merely the loopback host."
  jq '.unrelatedPort' <<<"$ntfy_json"
  exit 1
fi

echo "✅ ntfy loopback-only, no-tunnel, and no-credential invariants passed."