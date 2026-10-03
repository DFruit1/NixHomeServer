#!/usr/bin/env bash

# Resource containment for the long-running services that were still uncapped
# (audit MEDIUM-1, card t_db10a39b). The caps themselves are decided centrally in
# system-resources.nix; this test asserts the evaluated result: the decided
# values, that the soft limit never exceeds the hard limit, that no capped unit
# is a oneshot, and that disabling an application module leaves no cap behind.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix

host="$(test_default_host)"

# Units expected to carry a central MemoryHigh/MemoryMax, with the values
# asserted here so an accidental loosening has to be deliberate. The tunnel unit
# is named after vars.cloudflareTunnelName and is asserted separately below.
expected_caps_json='{
  "ipfs": { "MemoryHigh": "512M", "MemoryMax": "1G" },
  "opencloud": { "MemoryHigh": "2G", "MemoryMax": "4G" },
  "search-solr": { "MemoryHigh": "4G", "MemoryMax": "6G" },
  "syncthing": { "MemoryHigh": "512M", "MemoryMax": "1G" },
  "caddy": { "MemoryHigh": "512M", "MemoryMax": "1G" },
  "homepage": { "MemoryHigh": "256M", "MemoryMax": "512M" },
  "kanidm": { "MemoryHigh": "512M", "MemoryMax": "1G" }
}'

read -r -d '' eval_body <<'NIXEOF' || true
host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
cfg = (builtins.getAttr host f.nixosConfigurations).config;
settings = f.lib.nixhomeserverSettings.${host};
tunnel = "cloudflared-tunnel-" + settings.cloudflareTunnelName;
unit = name: let s = cfg.systemd.services.${name} or null; in
  if s == null then null
  else {
    type = s.serviceConfig.Type or "simple";
    inherit (s.serviceConfig) MemoryHigh MemoryMax;
  };
in {
  capped = lib.mapAttrs (name: _: unit name) {
    ipfs = null;
    opencloud = null;
    search-solr = null;
    syncthing = null;
    caddy = null;
    homepage = null;
    kanidm = null;
    ${tunnel} = null;
    # Jellyfin keeps its pre-existing caps: transcoding is the one workload
    # here whose burst is not represented by MemoryPeak.
    jellyfin = null;
  };
}
NIXEOF

caps_json="$(
  NIXHOMESERVER_TEST_HOST="$host" flake_eval_json "$eval_body"
)"

# Evaluate the disabled-application cases so a cap cannot outlive the unit it
# describes. Both ipfs and search are capped centrally.
disabled_json="$(
  NIXHOMESERVER_DISABLE_CASES=ipfs,search \
    NIXHOMESERVER_TEST_HOST="$host" \
    nix eval --impure --json --file scripts/tests/module-disable-matrix.nix
)"

# systemd size strings: a number followed by K/M/G/T/P/E (binary units) or a bare
# byte count. `infinity` means no limit.
to_bytes() {
  jq -n -e --arg size "$1" '
    def bytes:
      if $size == "infinity" then null
      else
        ($size | ascii_upcase) as $u
        | ($u | capture("^(?<n>[0-9]+)(?<u>[KMGTPE]?)$")) as $m
        | ($m.n | tonumber)
          * (if $m.u == "" then 1
             elif $m.u == "K" then 1024
             elif $m.u == "M" then 1048576
             elif $m.u == "G" then 1073741824
             elif $m.u == "T" then 1099511627776
             elif $m.u == "P" then 1125899906842624
             else 1152921504606846976
             end)
      end;
    bytes
  '
}

while read -r unit expected_high expected_max; do
  actual="$(jq -c --arg unit "$unit" '.capped[$unit] // null' <<<"$caps_json")"

  if [[ "$(jq -r '.MemoryHigh // "null"' <<<"$actual")" != "$expected_high" ]] \
    || [[ "$(jq -r '.MemoryMax // "null"' <<<"$actual")" != "$expected_max" ]]; then
    echo "❌ ${unit} does not carry its centrally decided memory caps (${expected_high}/${expected_max})." >&2
    jq --arg unit "$unit" '.capped[$unit]' <<<"$caps_json" >&2
    exit 1
  fi

  if [[ "$(jq -r '.type' <<<"$actual")" == "oneshot" ]]; then
    echo "❌ ${unit} is capped but is a oneshot; transient bootstrap units must stay uncapped." >&2
    exit 1
  fi

  high_bytes="$(to_bytes "$expected_high")"
  max_bytes="$(to_bytes "$expected_max")"
  if ((high_bytes > max_bytes)); then
    echo "❌ ${unit}: MemoryHigh (${high_bytes} bytes) exceeds MemoryMax (${max_bytes} bytes)." >&2
    exit 1
  fi
done < <(jq -r 'to_entries[] | "\(.key) \(.value.MemoryHigh) \(.value.MemoryMax)"' <<<"$expected_caps_json")

# The tunnel unit is named after vars.cloudflareTunnelName.
tunnel_unit="$(jq -r '.capped | keys[] | select(startswith("cloudflared-tunnel-"))' <<<"$caps_json")"
if [[ -z "$tunnel_unit" ]]; then
  echo "❌ No cloudflared tunnel unit carries a central memory cap." >&2
  exit 1
fi

jq -e --arg tunnel "$tunnel_unit" '
  .capped[$tunnel] == { "MemoryHigh": "1G", "MemoryMax": "2G", "type": "simple" }
' <<<"$caps_json" >/dev/null || {
  echo "❌ The Cloudflare tunnel must keep its 1G/2G long-running caps." >&2
  jq --arg tunnel "$tunnel_unit" '.capped[$tunnel]' <<<"$caps_json" >&2
  exit 1
}

# Jellyfin keeps the caps it already had: transcoding is the one workload whose
# burst MemoryPeak does not represent.
jq -e '.capped.jellyfin == { "MemoryHigh": "1G", "MemoryMax": "2G", "type": "simple" }' \
  <<<"$caps_json" >/dev/null || {
  echo "❌ Jellyfin must keep its existing 1G/2G caps." >&2
  jq .capped.jellyfin <<<"$caps_json" >&2
  exit 1
}

jq -e 'all(.[]; .valid)' <<<"$disabled_json" >/dev/null || {
  echo "❌ Disabling an application left runtime state behind, so its central memory cap could outlive the unit." >&2
  jq . <<<"$disabled_json" >&2
  exit 1
}

echo "✅ Central memory containment evaluates with the decided caps, MemoryHigh below MemoryMax, no capped oneshots, and no cap surviving module disable."