#!/usr/bin/env bash

set -euo pipefail

printf '%s\t%s\n' "${RCLONE_CAPACITY_REPOSITORY_BYTES:?RCLONE_CAPACITY_REPOSITORY_BYTES is required}" "${!#}"
