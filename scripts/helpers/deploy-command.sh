#!/usr/bin/env bash

build_nixos_rebuild_command() {
  local -n output_command="$1"
  local action="$2"
  local hostname="$3"
  local build_locally="$4"
  local target_host="$5"
  local build_host="$6"

  output_command=(
    nix run --inputs-from . nixpkgs#nixos-rebuild --
    "$action" --flake ".#${hostname}" --sudo
  )
  if [[ "$build_locally" == "true" || "$target_host" != "$build_host" ]]; then
    output_command+=(--target-host "$target_host")
  fi
}
