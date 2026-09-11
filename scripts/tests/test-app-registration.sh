#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
ensure_tools nix jq

result="$(flake_eval_json '
  merge = import ./lib/merge-ports.nix { inherit lib; };
  accepts = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  catalog = import ./modules/catalog.nix;
  base = f.lib.nixhomeserverSettings.${testHost};
  testHost = builtins.head (builtins.attrNames f.lib.nixhomeserverSettings);
  without = app: import ./lib/derive-vars.nix {
    inherit lib;
    settings = base // { applications = { enabled = builtins.filter (name: name != app) base.enabledApps; }; };
  };
  oneApp = base // { applications = { enabled = [ "audiobookshelf" ]; }; };
  oneAppVars = import ./lib/derive-vars.nix { inherit lib; settings = oneApp; };
in {
  merged = merge [ { core = 80; } { app = 1234; } ];
  rejectsDuplicate = !(accepts (merge [ { app = 1; } { app = 2; } ]));
  rejectsInvalid = !(accepts (merge [ { app = 65536; } ]));
  rejectsString = !(accepts (merge [ { app = "1234"; } ]));
  registeredPort = oneAppVars.networking.ports.audiobookshelf == catalog.apps.audiobookshelf.registration.ports.audiobookshelf;
  removesPort = !((without "audiobookshelf").networking.ports ? audiobookshelf);
  noSiblingPort = !(oneAppVars.networking.ports ? jellyfin);
}')"
jq -e '.merged == {core:80,app:1234} and (del(.merged) | all(.[]; . == true))' <<<"$result" >/dev/null
echo '✅ Application port registration, removal, and validation passed.'
