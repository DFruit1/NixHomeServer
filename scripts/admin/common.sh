#!/usr/bin/env bash

set -euo pipefail

admin_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$admin_script_dir/../helpers/repo-common.sh"
init_repo_root NIXHOMESERVER_REPO_ROOT
cd_repo_root
ensure_default_nix_config

status_ready=0
status_warning=0
status_blocked=0

need() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "blocked: missing required tool: $tool"
      status_blocked=$((status_blocked + 1))
    fi
  done
}

ready() {
  echo "ready: $*"
  status_ready=$((status_ready + 1))
}

warn() {
  echo "warning: $*"
  status_warning=$((status_warning + 1))
}

block() {
  echo "blocked: $*"
  status_blocked=$((status_blocked + 1))
}

finish_report() {
  echo
  echo "summary: ${status_ready} ready, ${status_warning} warning, ${status_blocked} blocked"
  if ((status_blocked > 0)); then
    exit 1
  fi
}

default_host() {
  if [[ -n "${NIXHOMESERVER_DEFAULT_HOST:-}" ]]; then
    printf '%s\n' "$NIXHOMESERVER_DEFAULT_HOST"
    return 0
  fi

  if ! command -v nix >/dev/null 2>&1; then
    echo "blocked: missing required tool: nix" >&2
    exit 1
  fi

  nix eval --raw --impure --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      lib = flake.inputs.nixpkgs.lib;
      vars = import ${repo_root}/vars.nix { inherit lib; };
    in
      vars.hostname
  "
}

nix_json_for_host() {
  local host="$1"
  local expr="$2"
  nix eval --json --impure --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      cfg = flake.nixosConfigurations.${host}.config;
    in
      ${expr}
  "
}

inventory_json_for_host() {
  local host="$1"

  nix_json_for_host "$host" "
    let
      settings = removeAttrs flake.lib.nixhomeserverSettings.${host} [
        \"kanidmIssuer\"
        \"kanidmDiscoveryUrl\"
      ];
      tunnel = cfg.services.cloudflared.tunnels.\${settings.cloudflareTunnelName};
      secretManifest = import ${repo_root}/secrets/manifest.nix;
    in
    {
      schemaVersion = 1;
      host = \"${host}\";
      inherit settings;
      network = {
        caddyHosts = builtins.attrNames cfg.services.caddy.virtualHosts;
        cloudflaredHosts = builtins.attrNames tunnel.ingress;
        privateDnsHosts = cfg.services.unbound.privateHosts;
        ports = settings.networking.ports;
      };
      identity = {
        kanidmGroups = builtins.attrNames cfg.services.kanidm.provision.groups;
        oauthClients = builtins.attrNames cfg.services.kanidm.provision.systems.oauth2;
      };
      storage = {
        profile = settings.storageProfile;
        dataRootIsMountPoint = settings.dataRootIsMountPoint;
        dataRoot = settings.dataRoot;
        usersRoot = settings.usersRoot;
        sharedRoot = settings.sharedRoot;
        backupRoot = settings.backupRoot;
        dataPool = settings.zfsDataPool;
        userContentSubdirs = cfg.repo.storage.userRoots.contentSubdirs;
        sharedContentSubdirs = cfg.repo.storage.sharedRoots.contentSubdirs;
      };
      backups = {
        inherit (cfg.repo.backups)
          appStateEntries
          criticalPaths
          pathInventories
          sqliteDumps;
        phoneBackup = {
          inherit (settings.phoneBackup)
            enable
            maxRepositoryBytes
            minimumSuccessfulSnapshots
            repositoryPath
            stateDir;
          syncthing = {
            inherit (settings.phoneBackup.syncthing)
              deviceName
              folderId;
          };
          sources = settings.phoneBackup.sources;
        };
      };
      impermanence = {
        directories = cfg.repo.impermanence.inventory.persistenceDirectories;
        files = cfg.repo.impermanence.inventory.persistenceFiles;
      };
      secrets = {
        ageSecretNames = builtins.attrNames cfg.age.secrets;
        externalSecretNames = builtins.attrNames secretManifest.externalSecrets;
      };
      systemd = {
        serviceNames = builtins.attrNames cfg.systemd.services;
      };
    }
  "
}
