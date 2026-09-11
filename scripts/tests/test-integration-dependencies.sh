#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools nix jq

result="$(flake_eval_json '
  catalog = import ./modules/catalog.nix;
  definitions = catalog.integrationDefinitions;
  select = import ./lib/select-integrations.nix { inherit lib; };
  names = entries: map (entry: builtins.baseNameOf entry.module) entries;
  valid = entry: lib.all (name: builtins.hasAttr name catalog.apps) (entry.allApps ++ entry.anyApps)
    && (entry.allApps != [ ] || entry.anyApps != [ ]);
  synthetic = [
    { module = "both"; allApps = [ "a" "b" ]; anyApps = [ ]; }
    { module = "one"; allApps = [ ]; anyApps = [ "a" "b" ]; }
  ];
  overrideFile = builtins.getEnv "NIXHOMESERVER_ENABLED_APPS_FILE";
  host = builtins.head (builtins.attrNames f.lib.nixhomeserverSettings);
  enabled = if overrideFile == "" then f.lib.nixhomeserverSettings.${host}.enabledApps
    else lib.splitString "," (lib.removeSuffix "\n" (builtins.readFile overrideFile));
in {
  declared = names definitions;
  files = builtins.filter (name: lib.hasSuffix ".nix" name) (builtins.attrNames (builtins.readDir ./modules/Integrations));
  valid = lib.all valid definitions;
  unique = builtins.length definitions == builtins.length (lib.unique (names definitions));
  none = names (select synthetic [ ]);
  single = names (select synthetic [ "a" ]);
  both = names (select synthetic [ "a" "b" ]);
  selected = names (select definitions enabled);
}')"
jq -e '
  (.declared | sort) == (.files | sort) and .valid and .unique
  and .none == [] and .single == ["one"] and .both == ["both", "one"]
' <<<"$result" >/dev/null
printf '✅ Catalog integration definitions and selection rules are valid.\n'
