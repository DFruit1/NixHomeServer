#!/usr/bin/env bash
set -euo pipefail

data_path="${FRESHRSS_DATA_PATH:?FRESHRSS_DATA_PATH is required}"
username_pattern="${FRESHRSS_USERNAME_PATTERN:?FRESHRSS_USERNAME_PATTERN is required}"
allowed_users_file="${FRESHRSS_ALLOWED_USERS_FILE:?FRESHRSS_ALLOWED_USERS_FILE is required}"

users_root="$data_path/users"
retired_root="$data_path/.retired-users"

if [[ ! -d "$users_root" ]]; then
	exit 0
fi

if [[ ! -r "$allowed_users_file" ]]; then
	echo "Allowed FreshRSS users file is not readable: $allowed_users_file" >&2
	exit 1
fi

mapfile -t allowed_users < "$allowed_users_file"

is_allowed() {
	local username="$1"
	local entry
	for entry in "${allowed_users[@]:-}"; do
		[[ "$username" == "$entry" ]] && return 0
	done
	return 1
}

mkdir -p "$retired_root"

while IFS= read -r -d '' account_dir; do
	username="$(basename "$account_dir")"
	if [[ ! "$username" =~ $username_pattern ]]; then
		continue
	fi
	if is_allowed "$username"; then
		continue
	fi

	retired_path="$retired_root/$username"
	if [[ -e "$retired_path" ]]; then
		rm -rf -- "$retired_path"
	fi
	mv -- "$account_dir" "$retired_path"
	echo "Retired FreshRSS account for removed user: $username"
done < <(find "$users_root" -mindepth 1 -maxdepth 1 -type d -print0)