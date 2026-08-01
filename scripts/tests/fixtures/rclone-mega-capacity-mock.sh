#!/usr/bin/env bash

set -euo pipefail

[[ "${1:-}" == about ]] || {
  echo "Unexpected mocked rclone command: ${1:-missing}" >&2
  exit 2
}
[[ -z "${RCLONE_CAPACITY_ERROR_EXIT:-}" ]] || exit "$RCLONE_CAPACITY_ERROR_EXIT"
cat "${RCLONE_CAPACITY_QUOTA_FILE:?RCLONE_CAPACITY_QUOTA_FILE is required}"
