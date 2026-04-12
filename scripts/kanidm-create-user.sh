#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_tty() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "$SCRIPT_NAME requires an interactive terminal." >&2
    exit 1
  fi
}

restore_terminal() {
  stty sane < /dev/tty >/dev/null 2>&1 || true
  tput cnorm >/dev/null 2>&1 || true
  tput rmcup >/dev/null 2>&1 || true
  printf '\033[0m' > /dev/tty 2>/dev/null || true
}

cleanup() {
  restore_terminal
  [[ -n "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

resolve_repo_root() {
  local candidate

  for candidate in \
    "${KANIDM_TUI_REPO_ROOT:-}" \
    "$SCRIPT_DIR/.." \
    "$PWD"
  do
    [[ -n "$candidate" ]] || continue
    candidate="$(cd "$candidate" && pwd)"
    if [[ -f "$candidate/vars.nix" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "Could not locate repository root containing vars.nix." >&2
  exit 1
}

nix_eval_var() {
  local attr="$1"
  nix eval --impure --raw --expr "
    let
      pkgs = import <nixpkgs> {};
      vars = import (/. + \"$REPO_ROOT/vars.nix\") { lib = pkgs.lib; };
    in vars.${attr}
  "
}

msg_box() {
  whiptail --title "$1" --msgbox "$2" 14 90
  restore_terminal
}

error_box() {
  whiptail --title "${1:-Error}" --msgbox "$2" 14 90
  restore_terminal
}

confirm_box() {
  local status=0

  if ! whiptail --title "$1" --yesno "$2" 14 90; then
    status=$?
  fi

  restore_terminal
  return "$status"
}

input_box() {
  local title="$1"
  local prompt="$2"
  local default_value="${3:-}"
  local result

  result="$(
    whiptail \
      --title "$title" \
      --inputbox "$prompt" 14 90 "$default_value" \
      3>&1 1>&2 2>&3
  )" || return 1

  restore_terminal

  printf '%s\n' "$(trim "$result")"
}

menu_box() {
  local title="$1"
  local prompt="$2"
  shift 2
  local status=0
  local result

  if ! result="$(
    whiptail \
      --title "$title" \
      --menu "$prompt" 22 100 12 \
      "$@" \
      3>&1 1>&2 2>&3
  )"; then
    status=$?
  fi

  restore_terminal
  [[ "$status" -eq 0 ]] || return "$status"
  printf '%s\n' "$result"
}

checklist_box() {
  local title="$1"
  local prompt="$2"
  shift 2
  local status=0
  local result

  if ! result="$(
    whiptail \
      --title "$title" \
      --checklist "$prompt" 24 100 14 \
      "$@" \
      3>&1 1>&2 2>&3
  )"; then
    status=$?
  fi

  restore_terminal
  [[ "$status" -eq 0 ]] || return "$status"
  printf '%s\n' "$result"
}

textbox_from_text() {
  local title="$1"
  local body="$2"
  local file="$TMP_DIR/textbox-$$.txt"
  printf 'Close this window with Tab, then Enter.\n\n%s\n' "$body" >"$file"
  whiptail --title "$title" --scrolltext --textbox "$file" 28 110
  restore_terminal
}

show_text_block() {
  local title="$1"
  local body="$2"
  local line_count max_width

  line_count="$(printf '%s\n' "$body" | wc -l | tr -d ' ')"
  max_width="$(printf '%s\n' "$body" | awk '{ if (length > max) max = length } END { print max + 0 }')"

  if [[ "$line_count" -le 12 && "$max_width" -le 78 ]]; then
    msg_box "$title" "$body"
    return 0
  fi

  textbox_from_text "$title" "$body"
}

run_command_capture() {
  local stdout_file="$TMP_DIR/cmd-out-$$.txt"
  local status=0

  if ! "$@" >"$stdout_file" 2>&1; then
    status=$?
  fi

  LAST_COMMAND_OUTPUT="$(cat "$stdout_file")"
  LAST_COMMAND_STATUS="$status"
  return 0
}

run_command_interactive() {
  local status=0

  clear >/dev/null 2>&1 || true
  printf 'Running command in the terminal below.\n'
  printf 'When it finishes, press Enter to return to the menu.\n\n'
  printf '+'
  printf ' %q' "$@"
  printf '\n\n'

  set +e
  "$@"
  status=$?
  set -e

  printf '\n'
  stty sane 2>/dev/null || true
  read -r -p "Press Enter to return to the menu..." < /dev/tty || true
  clear >/dev/null 2>&1 || true

  LAST_COMMAND_OUTPUT="Interactive command output was shown directly in the terminal above."
  LAST_COMMAND_STATUS="$status"
  return 0
}

show_command_result() {
  local title="$1"
  local prefix="${2:-}"
  local body=""

  if [[ -n "$prefix" ]]; then
    body+="$prefix"$'\n\n'
  fi
  body+="Exit status: $LAST_COMMAND_STATUS"$'\n\n'
  if [[ -n "$LAST_COMMAND_OUTPUT" ]]; then
    body+="$LAST_COMMAND_OUTPUT"
  else
    body+="(no output)"
  fi

  show_text_block "$title" "$body"
}

require_success() {
  local title="$1"
  local prefix="$2"
  if [[ "$LAST_COMMAND_STATUS" -ne 0 ]]; then
    show_command_result "$title" "$prefix"
    return 1
  fi
  return 0
}

parse_name_list() {
  awk '
    NF == 0 { next }
    {
      name=$1
      gsub(/[:,]/, "", name)
      low=tolower(name)
      if (low == "name" || low == "group" || low == "groups" || low == "spn" ||
          low == "uuid" || low == "display" || low == "displayname" ||
          low == "account" || low == "account_id") next
      print name
    }
  ' | awk '!seen[$0]++'
}

fetch_group_names() {
  run_command_capture kanidm group list --url "$SERVER_URL" --name "$ADMIN_NAME"
  require_success "Group List" "Could not read groups from Kanidm." || return 1
  mapfile -t GROUP_NAMES < <(printf '%s\n' "$LAST_COMMAND_OUTPUT" | parse_name_list)
}

fetch_person_names() {
  run_command_capture kanidm person list --url "$SERVER_URL" --name "$ADMIN_NAME"
  require_success "Person List" "Could not read users from Kanidm." || return 1
  mapfile -t PERSON_NAMES < <(printf '%s\n' "$LAST_COMMAND_OUTPUT" | parse_name_list)
}

list_to_menu_items() {
  local -n values_ref=$1
  # shellcheck disable=SC2178
  local -n items_ref=$2
  local value

  items_ref=()
  for value in "${values_ref[@]}"; do
    items_ref+=("$value" "")
  done
}

list_to_checklist_items() {
  local -n values_ref=$1
  # shellcheck disable=SC2178
  local -n items_ref=$2
  local value

  items_ref=()
  for value in "${values_ref[@]}"; do
    items_ref+=("$value" "" OFF)
  done
}

choose_person() {
  local title="$1"
  local prompt="$2"
  local manual_choice="__manual__"
  local choice
  local menu_items

  fetch_person_names || return 1

  if [[ "${#PERSON_NAMES[@]}" -eq 0 ]]; then
    choice="$manual_choice"
  else
    list_to_menu_items PERSON_NAMES menu_items
    menu_items+=("$manual_choice" "Enter an account id manually")
    choice="$(menu_box "$title" "$prompt" "${menu_items[@]}")" || return 1
  fi

  if [[ "$choice" == "$manual_choice" ]]; then
    choice="$(input_box "$title" "Enter the Kanidm account id to manage.")" || return 1
  fi

  choice="$(trim "$choice")"
  [[ -n "$choice" ]] || return 1
  printf '%s\n' "$choice"
}

choose_groups() {
  local title="$1"
  local prompt="$2"
  local raw
  local checklist_items

  fetch_group_names || return 1

  if [[ "${#GROUP_NAMES[@]}" -eq 0 ]]; then
    SELECTED_GROUPS=()
    msg_box "$title" "No groups were returned by Kanidm."
    return 0
  fi

  list_to_checklist_items GROUP_NAMES checklist_items
  raw="$(checklist_box "$title" "$prompt" "${checklist_items[@]}")" || return 1

  SELECTED_GROUPS=()
  if [[ -n "$raw" ]]; then
    local group_name
    eval "set -- $raw"
    for group_name in "$@"; do
      SELECTED_GROUPS+=("${group_name%\"}")
      SELECTED_GROUPS[-1]="${SELECTED_GROUPS[-1]#\"}"
    done
  fi
}

show_current_settings() {
  msg_box \
    "Current Settings" \
    "Repository root: $REPO_ROOT

Server URL: $SERVER_URL
Admin username: $ADMIN_NAME
Admin email from vars.nix: $ADMIN_EMAIL

Override any of these at launch if needed:
  KANIDM_TUI_REPO_ROOT=/path/to/repo
  KANIDM_TUI_SERVER_URL=https://id.example.org
  KANIDM_TUI_ADMIN_NAME=admindsaw
  KANIDM_TUI_ADMIN_EMAIL=admin@example.org"
}

configure_connection() {
  local value

  value="$(input_box "Server URL" "Kanidm server URL." "$SERVER_URL")" || return 1
  SERVER_URL="$value"

  value="$(input_box "Admin Username" "Kanidm admin username to use for CLI operations." "$ADMIN_NAME")" || return 1
  ADMIN_NAME="$value"

  value="$(input_box "Admin Email" "Reference email loaded from vars.nix." "$ADMIN_EMAIL")" || return 1
  ADMIN_EMAIL="$value"
}

login_flow() {
  msg_box "Login" "The next step runs 'kanidm login' in the terminal below this dialog. Enter the password there when prompted."
  run_command_interactive kanidm login --url "$SERVER_URL" --name "$ADMIN_NAME"
  show_command_result "Login Result" "Login attempt finished."
}

reauth_flow() {
  msg_box "Reauthenticate" "The next step runs 'kanidm reauth' in the terminal below this dialog. Enter the password there when prompted."
  run_command_interactive kanidm reauth --url "$SERVER_URL" --name "$ADMIN_NAME"
  show_command_result "Reauth Result" "Privileged reauthentication attempt finished."
}

session_flow() {
  run_command_capture kanidm session list --url "$SERVER_URL" --name "$ADMIN_NAME"
  show_command_result "CLI Sessions" "Current Kanidm CLI sessions."
}

list_people_flow() {
  run_command_capture kanidm person list --url "$SERVER_URL" --name "$ADMIN_NAME"
  show_command_result "Kanidm Users" "Known Kanidm person accounts."
}

view_person_flow() {
  local account_id
  account_id="$(choose_person "View User" "Select a Kanidm user to inspect.")" || return 1
  run_command_capture kanidm person get "$account_id" --url "$SERVER_URL" --name "$ADMIN_NAME"
  show_command_result "User Detail" "Record for '$account_id'."
}

create_user_flow() {
  local account_id display_name primary_email begin_from expire_at ttl summary group_lines=""
  local request_reset_token="n"

  account_id="$(input_box "Create User" "New account id / username.")" || return 1
  [[ -n "$account_id" ]] || return 1

  display_name="$(input_box "Create User" "Display name for '$account_id'.")" || return 1
  [[ -n "$display_name" ]] || return 1

  primary_email="$(input_box "Create User" "Primary email. Leave blank to skip." "")" || return 1

  choose_groups "Create User" "Select groups to assign during creation." || return 1

  begin_from=""
  if confirm_box "Validity Window" "Set a begin-from validity timestamp?"; then
    begin_from="$(input_box "Begin-From" "RFC3339 timestamp. Example: 2026-04-12T17:30:00+10:00" "$(date -Is)")" || return 1
  fi

  expire_at=""
  if confirm_box "Validity Window" "Set an expiry timestamp?"; then
    expire_at="$(input_box "Expire-At" "RFC3339 timestamp or 'now'." "now")" || return 1
  fi

  ttl=""
  if confirm_box "Reset Token" "Generate a password reset token after creation?"; then
    request_reset_token="y"
    ttl="$(input_box "Reset Token TTL" "TTL in seconds. Leave blank for Kanidm default (3600)." "")" || return 1
    if [[ -n "$ttl" && ! "$ttl" =~ ^[0-9]+$ ]]; then
      error_box "Reset Token TTL" "TTL must be blank or a whole number of seconds."
      return 1
    fi
  fi

  if [[ "${#SELECTED_GROUPS[@]}" -gt 0 ]]; then
    group_lines="$(printf '  - %s\n' "${SELECTED_GROUPS[@]}")"
  else
    group_lines="  (none)"
  fi

  summary="Server URL: $SERVER_URL
Admin username: $ADMIN_NAME
Account id: $account_id
Display name: $display_name
Primary email: ${primary_email:-"(none)"}

Groups:
$group_lines

Begin-from: ${begin_from:-"(not set)"}
Expire-at: ${expire_at:-"(not set)"}
Reset token TTL: $(
  if [[ "$request_reset_token" == "y" ]]; then
    printf '%s' "${ttl:-"(default Kanidm TTL)"}"
  else
    printf '%s' "(not requested)"
  fi
)"

  show_text_block "Create User Summary" "$summary"
  confirm_box "Create User" "Proceed with creation of '$account_id'?" || return 0

  run_command_capture kanidm person create "$account_id" "$display_name" --url "$SERVER_URL" --name "$ADMIN_NAME"
  require_success "Create User" "User creation failed." || return 1

  if [[ -n "$primary_email" ]]; then
    run_command_capture kanidm person update "$account_id" --mail "$primary_email" --url "$SERVER_URL" --name "$ADMIN_NAME"
    require_success "Set Email" "User was created, but setting the primary email failed." || return 1
  fi

  if [[ "${#SELECTED_GROUPS[@]}" -gt 0 ]]; then
    local group_name
    for group_name in "${SELECTED_GROUPS[@]}"; do
      run_command_capture kanidm group add-members "$group_name" "$account_id" --url "$SERVER_URL" --name "$ADMIN_NAME"
      require_success "Add Group" "User was created, but adding '$account_id' to '$group_name' failed." || return 1
    done
  fi

  if [[ -n "$begin_from" ]]; then
    run_command_capture kanidm person validity begin-from "$account_id" "$begin_from" --url "$SERVER_URL" --name "$ADMIN_NAME"
    require_success "Set Begin-From" "User was created, but setting begin-from failed." || return 1
  fi

  if [[ -n "$expire_at" ]]; then
    run_command_capture kanidm person validity expire-at "$account_id" "$expire_at" --url "$SERVER_URL" --name "$ADMIN_NAME"
    require_success "Set Expiry" "User was created, but setting expiry failed." || return 1
  fi

  if [[ "$request_reset_token" == "y" && -n "$ttl" ]]; then
    run_command_capture kanidm person credential create-reset-token "$account_id" "$ttl" --url "$SERVER_URL" --name "$ADMIN_NAME"
    show_command_result "Reset Token" "User was created and a reset token was requested."
    return 0
  fi

  if [[ "$request_reset_token" == "y" ]]; then
    run_command_capture kanidm person credential create-reset-token "$account_id" --url "$SERVER_URL" --name "$ADMIN_NAME"
    show_command_result "Reset Token" "User was created and a reset token was requested."
    return 0
  fi

  run_command_capture kanidm person get "$account_id" --url "$SERVER_URL" --name "$ADMIN_NAME"
  show_command_result "User Created" "Final record for '$account_id'."
}

update_user_flow() {
  local account_id action value
  account_id="$(choose_person "Update User" "Select a Kanidm user to update.")" || return 1

  action="$(
    menu_box \
      "Update User" \
      "Choose an attribute to update for '$account_id'." \
      rename "Change account id / username" \
      display "Change display name" \
      email "Change primary email" \
      cancel "Return"
  )" || return 1

  case "$action" in
    rename)
      value="$(input_box "Rename User" "New account id for '$account_id'.")" || return 1
      [[ -n "$value" ]] || return 1
      run_command_capture kanidm person update "$account_id" --newname "$value" --url "$SERVER_URL" --name "$ADMIN_NAME"
      show_command_result "Rename User" "Rename attempt finished."
      ;;
    display)
      value="$(input_box "Display Name" "New display name for '$account_id'.")" || return 1
      [[ -n "$value" ]] || return 1
      run_command_capture kanidm person update "$account_id" --displayname "$value" --url "$SERVER_URL" --name "$ADMIN_NAME"
      show_command_result "Display Name" "Display name update finished."
      ;;
    email)
      value="$(input_box "Primary Email" "New primary email for '$account_id'.")" || return 1
      [[ -n "$value" ]] || return 1
      run_command_capture kanidm person update "$account_id" --mail "$value" --url "$SERVER_URL" --name "$ADMIN_NAME"
      show_command_result "Primary Email" "Primary email update finished."
      ;;
    *)
      return 0
      ;;
  esac
}

group_membership_flow() {
  local account_id action group_name
  account_id="$(choose_person "Group Membership" "Select a Kanidm user to change group membership for.")" || return 1

  action="$(
    menu_box \
      "Group Membership" \
      "Choose a group action for '$account_id'." \
      add "Add this user to one or more groups" \
      remove "Remove this user from one or more groups" \
      cancel "Return"
  )" || return 1

  case "$action" in
    add)
      choose_groups "Add Groups" "Select one or more groups to add '$account_id' to." || return 1
      [[ "${#SELECTED_GROUPS[@]}" -gt 0 ]] || return 0
      for group_name in "${SELECTED_GROUPS[@]}"; do
        run_command_capture kanidm group add-members "$group_name" "$account_id" --url "$SERVER_URL" --name "$ADMIN_NAME"
        require_success "Add Group" "Adding '$account_id' to '$group_name' failed." || return 1
      done
      msg_box "Add Groups" "Finished adding selected groups to '$account_id'."
      ;;
    remove)
      choose_groups "Remove Groups" "Select one or more groups to remove '$account_id' from." || return 1
      [[ "${#SELECTED_GROUPS[@]}" -gt 0 ]] || return 0
      for group_name in "${SELECTED_GROUPS[@]}"; do
        run_command_capture kanidm group remove-members "$group_name" "$account_id" --url "$SERVER_URL" --name "$ADMIN_NAME"
        require_success "Remove Group" "Removing '$account_id' from '$group_name' failed." || return 1
      done
      msg_box "Remove Groups" "Finished removing selected groups from '$account_id'."
      ;;
    *)
      return 0
      ;;
  esac
}

validity_flow() {
  local account_id action value
  account_id="$(choose_person "Validity Window" "Select a Kanidm user to manage validity for.")" || return 1

  action="$(
    menu_box \
      "Validity Window" \
      "Choose a validity action for '$account_id'." \
      show "Show current validity window" \
      begin "Set begin-from timestamp" \
      expire "Set expire-at timestamp" \
      cancel "Return"
  )" || return 1

  case "$action" in
    show)
      run_command_capture kanidm person validity show "$account_id" --url "$SERVER_URL" --name "$ADMIN_NAME"
      show_command_result "Validity Window" "Current validity for '$account_id'."
      ;;
    begin)
      value="$(input_box "Begin-From" "RFC3339 timestamp for '$account_id'." "$(date -Is)")" || return 1
      [[ -n "$value" ]] || return 1
      run_command_capture kanidm person validity begin-from "$account_id" "$value" --url "$SERVER_URL" --name "$ADMIN_NAME"
      show_command_result "Begin-From" "Begin-from update finished."
      ;;
    expire)
      value="$(input_box "Expire-At" "RFC3339 timestamp or 'now' for '$account_id'." "now")" || return 1
      [[ -n "$value" ]] || return 1
      run_command_capture kanidm person validity expire-at "$account_id" "$value" --url "$SERVER_URL" --name "$ADMIN_NAME"
      show_command_result "Expire-At" "Expiry update finished."
      ;;
    *)
      return 0
      ;;
  esac
}

reset_token_flow() {
  local account_id ttl
  account_id="$(choose_person "Reset Token" "Select a Kanidm user to generate a reset token for.")" || return 1
  ttl="$(input_box "Reset Token TTL" "TTL in seconds. Leave blank for Kanidm default (3600)." "")" || return 1

  if [[ -n "$ttl" && ! "$ttl" =~ ^[0-9]+$ ]]; then
    error_box "Reset Token TTL" "TTL must be blank or a whole number of seconds."
    return 1
  fi

  if [[ -n "$ttl" ]]; then
    run_command_capture kanidm person credential create-reset-token "$account_id" "$ttl" --url "$SERVER_URL" --name "$ADMIN_NAME"
  else
    run_command_capture kanidm person credential create-reset-token "$account_id" --url "$SERVER_URL" --name "$ADMIN_NAME"
  fi
  show_command_result "Reset Token" "Reset token request finished for '$account_id'."
}

delete_user_flow() {
  local account_id
  account_id="$(choose_person "Delete User" "Select a Kanidm user to delete.")" || return 1

  confirm_box "Delete User" "Delete '$account_id'? This cannot be undone from the TUI." || return 0
  confirm_box "Delete User" "Final confirmation: delete '$account_id' from Kanidm now?" || return 0

  run_command_capture kanidm person delete "$account_id" --url "$SERVER_URL" --name "$ADMIN_NAME"
  show_command_result "Delete User" "Delete request finished."
}

show_help() {
  msg_box \
    "Help" \
    "This terminal UI is a menu wrapper around the Kanidm CLI.

Defaults loaded from vars.nix:
  admin username: $DEFAULT_ADMIN_NAME
  admin email: $DEFAULT_ADMIN_EMAIL
  server URL: $DEFAULT_SERVER_URL

Typical workflow:
  1. Login
  2. Reauthenticate
  3. Create User or choose an existing user to manage

Notes:
  - group checklists show current Kanidm groups
  - password entry still happens in the terminal when Kanidm prompts
  - the script does not create app-local accounts in Immich, Paperless, or other apps
  - app-side rows are still created or linked on first successful OIDC login"
}

main_menu() {
  local choice
  while true; do
    choice="$(
      menu_box \
        "Kanidm User TUI" \
        "Server: $SERVER_URL | Admin: $ADMIN_NAME | Email: $ADMIN_EMAIL" \
        settings "Show current settings" \
        configure "Change server or admin defaults" \
        login "Login with Kanidm CLI" \
        reauth "Reauthenticate for privileged operations" \
        sessions "Show CLI sessions" \
        users "List current users" \
        view "View a user record" \
        create "Create a new user" \
        update "Update an existing user" \
        groups "Manage group membership" \
        validity "Manage validity window" \
        reset "Generate a reset token" \
        delete "Delete a user" \
        help "Help" \
        exit "Exit"
    )" || break

    case "$choice" in
      settings) show_current_settings ;;
      configure) configure_connection ;;
      login) login_flow ;;
      reauth) reauth_flow ;;
      sessions) session_flow ;;
      users) list_people_flow ;;
      view) view_person_flow ;;
      create) create_user_flow ;;
      update) update_user_flow ;;
      groups) group_membership_flow ;;
      validity) validity_flow ;;
      reset) reset_token_flow ;;
      delete) delete_user_flow ;;
      help) show_help ;;
      exit) break ;;
    esac
  done
}

require_tty
require_cmd bash
require_cmd kanidm
require_cmd nix
require_cmd whiptail
require_cmd mktemp

REPO_ROOT="$(resolve_repo_root)"
TMP_DIR="$(mktemp -d)"
trap cleanup EXIT
trap 'restore_terminal; exit 130' INT TERM HUP

DEFAULT_SERVER_URL="${KANIDM_TUI_SERVER_URL:-$(nix_eval_var kanidmBaseUrl)}"
DEFAULT_ADMIN_NAME="${KANIDM_TUI_ADMIN_NAME:-$(nix_eval_var kanidmAdminUser)}"
DEFAULT_ADMIN_EMAIL="${KANIDM_TUI_ADMIN_EMAIL:-$(nix_eval_var kanidmAdminEmail)}"

SERVER_URL="$DEFAULT_SERVER_URL"
ADMIN_NAME="$DEFAULT_ADMIN_NAME"
ADMIN_EMAIL="$DEFAULT_ADMIN_EMAIL"

LAST_COMMAND_OUTPUT=""
LAST_COMMAND_STATUS=0
SELECTED_GROUPS=()
GROUP_NAMES=()
PERSON_NAMES=()

main_menu
