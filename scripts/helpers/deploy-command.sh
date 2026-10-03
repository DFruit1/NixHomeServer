#!/usr/bin/env bash

build_nixos_rebuild_command() {
  local -n output_command="$1"
  local action="$2"
  local hostname="$3"
  local build_locally="$4"
  local target_host="$5"
  local build_host="$6"
  # A console deploy already runs as this machine's root identity and makes no
  # SSH connection, so it must never pass --target-host: that would send
  # nixos-rebuild back out over SSH as the local admin, which is exactly the
  # passwordless grant the console route exists to avoid needing.
  local local_target="${7:-false}"

  output_command=(
    nix run --inputs-from . nixpkgs#nixos-rebuild --
    "$action" --flake ".#${hostname}" --sudo
  )
  if [[ "$local_target" == "true" ]]; then
    return 0
  fi
  if [[ "$build_locally" == "true" || "$target_host" != "$build_host" ]]; then
    output_command+=(--target-host "$target_host")
  fi
}
