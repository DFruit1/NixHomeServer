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
      repoPath = builtins.getEnv \"NIXHOMESERVER_REPO_ROOT_FOR_EVAL\";
      flake = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
      lib = flake.inputs.nixpkgs.lib;
      vars = import (builtins.toPath (repoPath + \"/vars.nix\")) { inherit lib; };
    in
      vars.hostname
  "
}

validate_flake_host_name() {
  local host="$1"
  [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

nix_json_for_host() {
  local host="$1"
  local expr="$2"
  if ! validate_flake_host_name "$host"; then
    echo "blocked: invalid flake hostname: $host" >&2
    return 1
  fi
  NIXHOMESERVER_EVAL_HOST="$host" nix eval --json --impure --expr "
    let
      flake = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
      hostName = builtins.getEnv \"NIXHOMESERVER_EVAL_HOST\";
      cfg = (builtins.getAttr hostName flake.nixosConfigurations).config;
    in
      ${expr}
  "
}

inventory_json_for_host() {
  local host="$1"

  nix_json_for_host "$host" "
    let
      settings = removeAttrs (builtins.getAttr hostName flake.lib.nixhomeserverSettings) [
        \"kanidmIssuer\"
        \"kanidmDiscoveryUrl\"
      ];
      tunnel = cfg.services.cloudflared.tunnels.\${settings.cloudflareTunnelName};
      secretManifest = import (builtins.toPath (builtins.getEnv \"NIXHOMESERVER_REPO_ROOT_FOR_EVAL\" + \"/secrets/manifest.nix\"));
    in
    {
      schemaVersion = 2;
      host = hostName;
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
        authGateway = {
          inherit (cfg.repo.authGateway) enable mode domain port;
          protectedApps = cfg.repo.authGateway.protectedApps;
        };
      };
      storage = {
        profile = settings.storageProfile;
        rootFsType = cfg.fileSystems.\"/\".fsType;
        requiresZfs = settings.enableZfsDataPool;
        dataRootIsMountPoint = settings.dataRootIsMountPoint;
        dataRoot = settings.dataRoot;
        usersRoot = settings.usersRoot;
        sharedRoot = settings.sharedRoot;
        backupRoot = settings.backupRoot;
        dataPool = settings.zfsDataPool;
        userContentSubdirs = cfg.repo.storage.userRoots.contentSubdirs;
        sharedContentSubdirs = cfg.repo.storage.sharedRoots.contentSubdirs;
        zfsSnapshotPolicy = {
          enabled = cfg.services.zfs.autoSnapshot.enable or false;
          inherit (cfg.services.zfs.autoSnapshot) frequent hourly daily weekly monthly;
        };
      };
      backups = {
        inherit (cfg.repo.backups)
          appStateEntries
          criticalPaths
          snapshotRoots
          repositoryPath
          successfulStagingRoot
          successfulCurrentPath
          successfulGenerationRoot
          retainedSuccessfulGenerations
          minimumFreeBytes
          pathInventories
          sqliteDumps
          postgresqlDumps;
      };
      impermanence = {
        directories = cfg.repo.impermanence.inventory.persistenceDirectories;
        files = cfg.repo.impermanence.inventory.persistenceFiles;
      };
      secrets = {
        ageSecretNames = builtins.attrNames cfg.age.secrets;
        externalSecretNames = builtins.attrNames secretManifest.externalSecrets;
        requiredExternalSecretNames = builtins.filter
          (name: ((builtins.getAttr name secretManifest.externalSecrets).required or true))
          (builtins.attrNames secretManifest.externalSecrets);
        optionalExternalSecretNames = builtins.filter
          (name: !((builtins.getAttr name secretManifest.externalSecrets).required or true))
          (builtins.attrNames secretManifest.externalSecrets);
      };
      systemd = {
        serviceNames = builtins.attrNames cfg.systemd.services;
      };
    }
  "
}
