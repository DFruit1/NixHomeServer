#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"

ensure_tools jq nix rg

host="$(test_default_host)"
attic_json="$(
  nix eval --json ".#nixosConfigurations.${host}.config" \
    --apply 'cfg: {
      enabled = cfg.repo.attic.enable;
      atticdEnabled = cfg.services.atticd.enable;
      listen = cfg.services.atticd.settings.listen;
      apiEndpoint = cfg.services.atticd.settings.api-endpoint;
      allowedHosts = cfg.services.atticd.settings.allowed-hosts;
      substituters = cfg.nix.settings.substituters;
      extraOptions = cfg.nix.extraOptions;
      firewallPorts = cfg.networking.firewall.allowedTCPPorts;
      secretPresent = cfg.age.secrets ? atticServerEnv;
      persistence = cfg.repo.impermanence.inventory.persistenceDirectories;
      bootstrap = {
        after = cfg.systemd.services.attic-cache-bootstrap.after;
        requires = cfg.systemd.services.attic-cache-bootstrap.requires;
        script = cfg.systemd.services.attic-cache-bootstrap.script;
        restart = cfg.systemd.services.attic-cache-bootstrap.serviceConfig.Restart;
      };
      watcher = {
        after = cfg.systemd.services.attic-watch-store.after;
        requires = cfg.systemd.services.attic-watch-store.requires;
        execStart = cfg.systemd.services.attic-watch-store.serviceConfig.ExecStart;
        restart = cfg.systemd.services.attic-watch-store.serviceConfig.Restart;
      };
    }'
)"

disabled_json="$(
  nix eval --impure --json --expr "
    let
      f = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
      lib = f.inputs.nixpkgs.lib;
      disabledHost = f.nixosConfigurations.${host}.extendModules {
        modules = [ { repo.attic.enable = lib.mkForce false; } ];
      };
      cfg = disabledHost.config;
    in {
      atticdEnabled = cfg.services.atticd.enable;
      bootstrapWantedBy = cfg.systemd.services.attic-cache-bootstrap.wantedBy or [ ];
      watcherWantedBy = cfg.systemd.services.attic-watch-store.wantedBy or [ ];
      secretPresent = cfg.age.secrets ? atticServerEnv;
      substituterPresent =
        builtins.elem \"http://127.0.0.1:8080/nixhomeserver\"
          cfg.nix.settings.substituters;
      persistenceRetained =
        builtins.elem \"/var/lib/atticd\"
          cfg.repo.impermanence.inventory.persistenceDirectories;
    }
  "
)"

jq -e '
  .enabled
  and .atticdEnabled
  and (.listen == "127.0.0.1:8080")
  and (.apiEndpoint == "http://127.0.0.1:8080/")
  and ((.allowedHosts | sort) == (["127.0.0.1:8080", "localhost:8080"] | sort))
  and (.substituters | index("http://127.0.0.1:8080/nixhomeserver") != null)
  and (.extraOptions | contains("!include /var/lib/atticd/nix.conf"))
  and (.firewallPorts | index(8080) == null)
  and .secretPresent
  and (.persistence | index("/var/lib/atticd") != null)
  and (.bootstrap.after | index("atticd.service") != null)
  and (.bootstrap.requires | index("atticd.service") != null)
  and (.bootstrap.restart == "on-failure")
  and (.bootstrap.script | contains("cache_name=nixhomeserver"))
  and (.bootstrap.script | contains("token-file ="))
  and (.bootstrap.script | contains(">\"$client_token_file\""))
  and ((.bootstrap.script | contains("attic login")) | not)
  and (.bootstrap.script | contains("cache create \"$cache_name\" --public --priority 39"))
  and (.bootstrap.script | contains("cache configure \"$cache_name\""))
  and (.bootstrap.script | contains("extra-trusted-public-keys ="))
  and (.bootstrap.script | contains("try-restart nix-daemon.service"))
  and (.watcher.after | index("attic-cache-bootstrap.service") != null)
  and (.watcher.requires | index("attic-cache-bootstrap.service") != null)
  and (.watcher.execStart | contains("watch-store --jobs 2 nixhomeserver"))
  and (.watcher.restart == "always")
' <<<"$attic_json" >/dev/null || {
  echo "❌ Evaluated Attic cache contract is incomplete." >&2
  jq . <<<"$attic_json" >&2
  exit 1
}

jq -e '
  (.atticdEnabled | not)
  and (.bootstrapWantedBy == [])
  and (.watcherWantedBy == [])
  and (.secretPresent | not)
  and (.substituterPresent | not)
  and .persistenceRetained
' <<<"$disabled_json" >/dev/null || {
  echo "❌ Disabling Attic retained an active cache surface or lost persisted data." >&2
  jq . <<<"$disabled_json" >&2
  exit 1
}

require_fixed secrets/manifest.nix 'atticServerEnv = {' \
  "Attic's JWT signing environment must be manifest-managed"
require_fixed scripts/helpers/generate-managed-secrets.sh \
  'ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64=' \
  "Attic's generated secret must use the server's documented environment format"
require_fixed modules/Core_Modules/age/default.nix 'atticServerEnv = {' \
  "Attic's server environment must be materialized through agenix"
require_fixed documentation/operations.md 'systemctl status atticd.service attic-cache-bootstrap.service attic-watch-store.service' \
  "operations guidance must expose the Attic health boundary"
require_fixed documentation/custom-app-development.md 'attic cache info nixhomeserver' \
  "custom app guidance must explain how to inspect the development cache"

echo "✅ Attic local binary-cache configuration checks passed."
