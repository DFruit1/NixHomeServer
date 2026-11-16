#!/usr/bin/env bash
# One command: build the server (debug), snapshot nothing (pass a firmware
# tree), build the virtual logger, run the scenarios.
#
#   tests/vlogger/run.sh <firmware project dir> [run.py options]
#   GWL_FIRMWARE_DIR=<dir> tests/vlogger/run.sh [run.py options]
#
# <firmware project dir> is .../GWL_Firmware_V2.1/GWL_Firmware_V2.1 of a
# snapshot (git archive), never a live firmware worktree. Scratch goes to
# $TMPDIR (set it to a roomy directory; /tmp may be small).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../../../../.." && pwd)"
if [[ $# -gt 0 && -d "$1" ]]; then
  export GWL_FIRMWARE_DIR="$(cd "$1" && pwd)"
  shift
fi
: "${GWL_FIRMWARE_DIR:?pass the firmware project dir or set GWL_FIRMWARE_DIR}"
(cd "$repo/custom_apps" && cargo build -q -p groundwater-server)
pkgs=(nixpkgs#gcc nixpkgs#postgresql_16 nixpkgs#mosquitto nixpkgs#python3 nixpkgs#mtools)
export VL_MOSQ_INC="$(nix build --no-link --print-out-paths nixpkgs#mosquitto.dev)/include"
export VL_MOSQ_LIB="$(nix build --no-link --print-out-paths nixpkgs#mosquitto.lib)/lib"
export VL_CJSON_INC="$(nix build --no-link --print-out-paths nixpkgs#cjson)/include"
export VL_HOST_CC="${VL_HOST_CC:-$(command -v cc || true)}"
exec nix shell "${pkgs[@]}" -c env CC=gcc python3 "$here/run.py" "$@"
