#!/usr/bin/env bash

# Pin a mutable checkout to one immutable Nix store source before a destructive
# bootstrap derives any host or disk settings from it.
pin_bootstrap_source_snapshot() {
  local source_ref="$1"
  local pinned_path

  pinned_path="$(
    NIXHOMESERVER_BOOTSTRAP_SOURCE_REF="$source_ref" \
      nix eval --impure --raw --expr \
      '(builtins.getFlake (builtins.getEnv "NIXHOMESERVER_BOOTSTRAP_SOURCE_REF")).outPath'
  )" || {
    echo "❌ Nix did not return one immutable source snapshot in the local store." >&2
    return 1
  }
  pinned_path="$(readlink -f "$pinned_path")"
  if [[ ! "$pinned_path" =~ ^/nix/store/[0-9a-z]{32}-[^/]+$ ]] \
    || [[ ! -d "$pinned_path" ]]; then
    echo "❌ The pinned bootstrap source is not an accessible local store directory." >&2
    return 1
  fi

  NIXHOMESERVER_PINNED_SOURCE_PATH="$pinned_path"
  NIXHOMESERVER_PINNED_FLAKE_REF="path:${pinned_path}"
  export NIXHOMESERVER_PINNED_SOURCE_PATH NIXHOMESERVER_PINNED_FLAKE_REF
  export NIXHOMESERVER_FLAKE_REF_FOR_EVAL="$NIXHOMESERVER_PINNED_FLAKE_REF"
  export NIXHOMESERVER_REPO_ROOT_FOR_EVAL="$NIXHOMESERVER_PINNED_SOURCE_PATH"
}

build_pinned_disko_plan() {
  local host="$1"
  local configuration_suffix="${2:--bootstrap}"

  if [[ -z "${NIXHOMESERVER_PINNED_FLAKE_REF:-}" ]] \
    || [[ "${NIXHOMESERVER_FLAKE_REF_FOR_EVAL:-}" != "$NIXHOMESERVER_PINNED_FLAKE_REF" ]] \
    || [[ "${NIXHOMESERVER_REPO_ROOT_FOR_EVAL:-}" != "${NIXHOMESERVER_PINNED_SOURCE_PATH:-}" ]]; then
    echo "❌ The bootstrap source pin is missing or changed; refusing to build a disk plan." >&2
    return 1
  fi

  nix build --no-link --print-out-paths --no-update-lock-file --no-write-lock-file \
    "${NIXHOMESERVER_PINNED_FLAKE_REF}#nixosConfigurations.${host}${configuration_suffix}.config.system.build.diskoScript"
}

build_pinned_target_system() {
  local host="$1"

  if [[ -z "${NIXHOMESERVER_PINNED_FLAKE_REF:-}" ]] \
    || [[ "${NIXHOMESERVER_FLAKE_REF_FOR_EVAL:-}" != "$NIXHOMESERVER_PINNED_FLAKE_REF" ]] \
    || [[ "${NIXHOMESERVER_REPO_ROOT_FOR_EVAL:-}" != "${NIXHOMESERVER_PINNED_SOURCE_PATH:-}" ]]; then
    echo "❌ The bootstrap source pin is missing or changed; refusing to build the target system." >&2
    return 1
  fi

  nix build --no-link --print-out-paths --no-update-lock-file --no-write-lock-file \
    "${NIXHOMESERVER_PINNED_FLAKE_REF}#nixosConfigurations.${host}.config.system.build.toplevel"
}

validate_pinned_target_system() {
  local system_path="$1"
  local canonical_system

  canonical_system="$(readlink -f -- "$system_path" 2>/dev/null || true)"
  if [[ ! "$system_path" =~ ^/nix/store/[0-9a-z]{32}-[^/[:space:]]+$ ]] \
    || [[ "$system_path" == *$'\n'* ]] \
    || [[ "$canonical_system" != "$system_path" ]] \
    || [[ ! -d "$system_path" ]] \
    || [[ ! -x "$system_path/activate" ]] \
    || [[ ! -x "$system_path/bin/switch-to-configuration" ]]; then
    echo "❌ Nix did not return one complete, immutable target-system closure." >&2
    return 1
  fi
}

validate_pinned_disko_plan() {
  local plan_path="$1"
  local canonical_plan

  canonical_plan="$(readlink -f -- "$plan_path" 2>/dev/null || true)"

  if [[ ! "$plan_path" =~ ^/nix/store/[0-9a-z]{32}-[^/[:space:]]+(/[^/[:space:]]+)*$ ]] \
    || [[ "$plan_path" == *$'\n'* ]] \
    || [[ "$canonical_plan" != "$plan_path" ]] \
    || [[ ! -f "$plan_path" ]] \
    || [[ ! -x "$plan_path" ]]; then
    echo "❌ Nix did not return one executable, immutable Disko plan." >&2
    return 1
  fi
}
