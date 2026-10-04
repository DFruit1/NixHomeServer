#!/usr/bin/env bash

# Check central caps on the selected host and through the same assertion path
# with optional applications disabled and removed. Never require an optional
# unit merely because it exists on the development host.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix
host="$(test_default_host)"

expected_caps_json='{
  "ipfs": { "MemoryHigh": "512M", "MemoryMax": "1G" },
  "opencloud": { "MemoryHigh": "2G", "MemoryMax": "4G" },
  "search-solr": { "MemoryHigh": "4G", "MemoryMax": "6G" },
  "syncthing": { "MemoryHigh": "512M", "MemoryMax": "1G" },
  "caddy": { "MemoryHigh": "512M", "MemoryMax": "1G" },
  "homepage": { "MemoryHigh": "256M", "MemoryMax": "512M" },
  "kanidm": { "MemoryHigh": "512M", "MemoryMax": "1G" },
  "jellyfin": { "MemoryHigh": "1G", "MemoryMax": "2G" }
}'

# One evaluation batches all variants. remote_eval_batch_json is not available
# on this branch; flake_eval_json still shares one module evaluation per variant
# across all unit queries rather than launching one Nix process per assertion.
read -r -d '' eval_body <<'NIXEOF' || true
host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
base = builtins.getAttr host f.nixosConfigurations;
settings = f.lib.nixhomeserverSettings.${host};
tunnel = "cloudflared-tunnel-" + settings.cloudflareTunnelName;
optionalApps = [ "ipfs" "opencloud" "search" "offline-music" "jellyfin" ];
disabled = base.extendModules {
  specialArgs.vars = settings // {
    offlineMedia = settings.offlineMedia // { enable = false; };
  };
  modules = [ ({ options, ... }: lib.mkMerge [
    (lib.optionalAttrs (lib.hasAttrByPath [ "repo" "ipfs" "enable" ] options) {
      repo.ipfs.enable = lib.mkForce false;
    })
    (lib.optionalAttrs (lib.hasAttrByPath [ "repo" "search" "enable" ] options) {
      repo.search.enable = lib.mkForce false;
    })
  ]) ];
};
removed = base.extendModules {
  modules = [{
    disabledModules = map (name: f.outPath + "/modules/${name}") optionalApps;
  }];
};
snapshot = evaluated: let
  cfg = evaluated.config;
  present = name: cfg.nixhomeserver.modules.${name} or false;
  enabled = {
    ipfs = cfg.services.kubo.enable;
    opencloud = cfg.services.opencloud.enable;
    search-solr = present "search" && (cfg.repo.search.enable or false);
    syncthing = cfg.services.syncthing.enable && cfg.services.syncthing.systemService;
    jellyfin = cfg.services.jellyfin.enable;
    homepage = present "homepage";
    caddy = true;
    kanidm = true;
    ${tunnel} = true;
  };
  unit = name: let s = cfg.systemd.services.${name} or null; in
    if s == null then null else {
      type = s.serviceConfig.Type or "simple";
      MemoryHigh = s.serviceConfig.MemoryHigh or null;
      MemoryMax = s.serviceConfig.MemoryMax or null;
    };
in {
  inherit enabled;
  capped = lib.mapAttrs (name: _: unit name) enabled;
  registry = lib.genAttrs optionalApps present;
};
in lib.mapAttrs (_: snapshot) { selected = base; inherit disabled removed; }
NIXEOF

caps_json="$(NIXHOMESERVER_TEST_HOST="$host" flake_eval_json "$eval_body")"

# Binary systemd size strings; null/infinity/malformed values must fail.
# Check exact limits, ordering in bytes, and non-oneshot type for enabled units;
# disabled units must be entirely absent (not merely missing their caps).
assert_caps() {
  jq -e --argjson expected "$expected_caps_json" '
    def bytes:
      tostring | ascii_upcase | capture("^(?<n>[0-9]+)(?<u>[KMGTPE]?)$")
      | (.n | tonumber) * (
          if .u == "" then 1 elif .u == "K" then 1024
          elif .u == "M" then 1048576 elif .u == "G" then 1073741824
          elif .u == "T" then 1099511627776
          elif .u == "P" then 1125899906842624 else 1152921504606846976 end);
    . as $snapshot
    | all(.enabled | to_entries[];
        .key as $name | $snapshot.capped[$name] as $actual
        | if .value then
            ($expected[$name] // {MemoryHigh: "1G", MemoryMax: "2G"}) as $limits
            | $actual != null
              and $actual.MemoryHigh == $limits.MemoryHigh
              and $actual.MemoryMax == $limits.MemoryMax
              and $actual.type != "oneshot"
              and (($actual.MemoryHigh | bytes) <= ($actual.MemoryMax | bytes))
          else $actual == null end)
  ' >/dev/null
}

for variant in selected disabled removed; do
  snapshot="$(jq -c --arg variant "$variant" '.[$variant]' <<<"$caps_json")"
  if ! assert_caps <<<"$snapshot"; then
    echo "❌ Central memory containment failed for ${variant}." >&2
    jq . <<<"$snapshot" >&2
    exit 1
  fi
  echo "✅ Central memory caps and unit absence: ${variant}."
done

# Prove the regression configurations actually exercise disabled/removed units,
# rather than letting a broken variant silently repeat the all-enabled host.
jq -e '
  (.disabled.enabled | (.ipfs or .["search-solr"] or .syncthing) | not)
  and (.removed.registry | all(.[]; not))
  and (.removed.enabled | (.ipfs or .opencloud or .["search-solr"] or .syncthing or .jellyfin) | not)
' <<<"$caps_json" >/dev/null || {
  echo "❌ Containment regression variants did not disable/remove the requested applications." >&2
  jq . <<<"$caps_json" >&2
  exit 1
}

echo "✅ Central memory containment: enabled caps, MemoryHigh <= MemoryMax, no capped oneshots, and no stale units in disabled/removed configurations."
