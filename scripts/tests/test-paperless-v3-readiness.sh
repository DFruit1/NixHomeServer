#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

: "${NIXHOMESERVER_FLAKE_REF_FOR_EVAL:?NIXHOMESERVER_FLAKE_REF_FOR_EVAL is required}"
host="$(test_default_host)"
export NIXHOMESERVER_TEST_HOST="$host"

current_json="$(
  nix eval --impure --json --expr '
    let
      flake = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
      host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
      cfg = (builtins.getAttr host flake.nixosConfigurations).config;
    in {
      inherit (cfg.repo.paperless.v3) enable candidateVersion;
      packageVersion = cfg.services.paperless.package.version;
      hasAi = cfg.services.paperless.settings ? PAPERLESS_AI_ENABLED;
      hasV2Polling = cfg.services.paperless.settings ? PAPERLESS_CONSUMER_POLLING;
      hasV3Polling = cfg.services.paperless.settings ? PAPERLESS_CONSUMER_POLLING_INTERVAL;
      oidcScript = cfg.systemd.services.paperless-oidc-env.script;
    }
  '
)"

jq -e '
  .enable == false
  and .candidateVersion == "2.20.15"
  and .packageVersion == "2.20.15"
  and (.hasAi | not)
  and .hasV2Polling
  and (.hasV3Polling | not)
  and (.oidcScript | contains("PAPERLESS_SECRET_KEY") | not)
' <<<"$current_json" >/dev/null || {
  echo "❌ Paperless v2 must remain active and free of v3-only settings."
  jq . <<<"$current_json"
  exit 1
}

v3_json="$(
  NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --json --expr '
    let
      flake = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
      host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
      base = builtins.getAttr host flake.nixosConfigurations;
      evaluated = base.extendModules {
        modules = [
          ({ pkgs, ... }: {
            repo.paperless.v3.enable = true;
            repo.paperless.v3.package = pkgs.paperless-ngx.overrideAttrs (_: {
              version = "3.0.0";
              __intentionallyOverridingVersion = true;
            });
          })
        ];
      };
      cfg = evaluated.config;
      settings = cfg.services.paperless.settings;
    in {
      packageVersion = cfg.services.paperless.package.version;
      aiEnabled = settings.PAPERLESS_AI_ENABLED;
      aiBackend = settings.PAPERLESS_AI_LLM_BACKEND;
      aiModel = settings.PAPERLESS_AI_LLM_MODEL;
      aiEndpoint = settings.PAPERLESS_AI_LLM_ENDPOINT;
      duplicatePolicy = settings.PAPERLESS_CONSUMER_DELETE_DUPLICATES;
      hasV2Polling = settings ? PAPERLESS_CONSUMER_POLLING;
      v3Polling = settings.PAPERLESS_CONSUMER_POLLING_INTERVAL;
      v3Stability = settings.PAPERLESS_CONSUMER_STABILITY_DELAY;
      preflightScript = cfg.systemd.services.paperless-v3-preflight.script;
      postMigrateScript = cfg.systemd.services.paperless-v3-post-migrate.script;
      oidcScript = cfg.systemd.services.paperless-oidc-env.script;
    }
  '
)"

jq -e '
  .packageVersion == "3.0.0"
  and .aiEnabled == "true"
  and .aiBackend == "openai-like"
  and .aiModel == "bonsai-ternary-27b"
  and .aiEndpoint == "http://127.0.0.1:8086/v1"
  and .duplicatePolicy == "true"
  and (.hasV2Polling | not)
  and .v3Polling == "60"
  and .v3Stability == "2"
  and (.preflightScript | contains("PRAGMA integrity_check"))
  and (.preflightScript | contains("storage_type = '\''gpg'\''"))
  and (.preflightScript | contains("paperless-v2.20.15.sqlite3"))
  and (.postMigrateScript | contains("document_index reindex --if-needed"))
  and (.postMigrateScript | contains("document_sanity_checker"))
  and (.oidcScript | contains("PAPERLESS_SECRET_KEY"))
' <<<"$v3_json" >/dev/null || {
  echo "❌ The dormant Paperless v3 profile is missing migration or Bonsai safeguards."
  jq . <<<"$v3_json"
  exit 1
}

failure_log="$(mktemp)"
trap 'rm -f "$failure_log"' EXIT
if NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --raw --expr '
  let
    flake = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
    base = builtins.getAttr host flake.nixosConfigurations;
    evaluated = base.extendModules {
      modules = [ { repo.paperless.v3.enable = true; } ];
    };
  in evaluated.config.system.build.toplevel.drvPath
' >"$failure_log" 2>&1; then
  echo "❌ The v3 switch accepted the current v2 nixpkgs unstable candidate."
  exit 1
fi
if ! rg -q 'requires nixpkgs unstable to provide Paperless-ngx 3.0.0 or newer' "$failure_log"; then
  echo "❌ The premature-v3 failure did not explain the nixpkgs version guard."
  cat "$failure_log"
  exit 1
fi

echo "✅ Paperless v2 remains active and the guarded v3/Bonsai profile evaluates as intended."
