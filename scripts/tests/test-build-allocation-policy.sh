#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

host="$(test_default_host)"

# Derived allocation policy for every supported build mode. Balanced mode is the
# only mode that bounds per-derivation cores; the others ask for all cores.
allocation_json="$(flake_eval_json '
  derive = settings: import ./lib/derive-vars.nix { inherit lib settings; };
  base = import ./vars.nix { inherit lib; };
  mode = name: import ./lib/derive-vars.nix {
    inherit lib;
    settings = base // { system = base.system // { buildMode = name; }; };
  };
  configuredVars = derive base;
in {
  configured = {
    buildMode = configuredVars.buildMode;
    inherit (configuredVars.buildSlots) local remote;
    cores = configuredVars.buildCores;
  };
  localMode = {
    slots = (mode "local").buildSlots;
    cores = (mode "local").buildCores;
  };
  remoteMode = {
    slots = (mode "remote").buildSlots;
    cores = (mode "remote").buildCores;
  };
  balanced = {
    slots = (mode "balanced").buildSlots;
    cores = (mode "balanced").buildCores;
  };
  maximumEffort = {
    slots = (mode "maximum-effort").buildSlots;
    cores = (mode "maximum-effort").buildCores;
  };
}
')"

if ! jq -e '
  # The committed default is the committed vars.nix mode; balanced here means
  # the two-slot, four-core bound on both hosts.
  (.configured.buildMode == "balanced")
  and (.configured.local == 2)
  and (.configured.remote == 2)
  and (.configured.cores == { local: 4, remote: 4 })

  and (.balanced.slots == { local: 2, remote: 2 })
  and (.balanced.cores == { local: 4, remote: 4 })

  # Every other mode keeps all slots on its own host and unbounded cores.
  and (.localMode.slots == { local: "auto", remote: 0 })
  and (.localMode.cores == { local: 0, remote: 0 })

  and (.remoteMode.slots == { local: 0, remote: "auto" })
  and (.remoteMode.cores == { local: 0, remote: 0 })

  and (.maximumEffort.slots == { local: "auto", remote: "auto" })
  and (.maximumEffort.cores == { local: 0, remote: 0 })
' <<<"$allocation_json" >/dev/null; then
  echo "❌ Derived build allocation policy regressed."
  jq . <<<"$allocation_json" >&2
  exit 1
fi

# The evaluated server daemon must consume the same policy: bounded cores and
# the two-slot limit in balanced mode, still build-capable if slots are zero.
daemon_json="$(NIXHOMESERVER_TEST_HOST="$host" flake_eval_json '
  host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  cfg = (builtins.getAttr host f.nixosConfigurations).config;
in {
  cores = cfg.nix.settings.cores;
  maxJobs = cfg.nix.settings.max-jobs;
}
')"

if ! jq -e '.cores == 4 and .maxJobs == 2' <<<"$daemon_json" >/dev/null; then
  echo "❌ The server Nix daemon does not apply the balanced allocation."
  jq . <<<"$daemon_json" >&2
  exit 1
fi

require_fixed lib/derive-vars.nix 'local = if buildMode == "balanced" then 4 else 0;' \
  "Balanced local allocation must stay bounded at four requested cores."
require_fixed lib/derive-vars.nix 'remote = if buildMode == "balanced" then 4 else 0;' \
  "Balanced remote allocation must stay bounded at four requested cores."
require_fixed modules/Core_Modules/base-system/default.nix 'cores = vars.buildCores.remote;' \
  "The deployed daemon must take its core hint from the derived allocation policy."
require_fixed scripts/deploy.sh 'local_build_cores="4"' \
  "The balanced one-shot deploy override must carry the same core bound."
require_fixed scripts/deploy.sh 'remote_build_cores="4"' \
  "The balanced one-shot deploy override must carry the same core bound for the server."
require_fixed documentation/operations.md '`balanced` sets Nix' \
  "Build-allocation runbook guidance must stay documented."

echo "✅ Build allocation policy and daemon settings checks passed."