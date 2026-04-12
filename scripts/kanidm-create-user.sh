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

require_cmd_optional() {
  command -v "$1" >/dev/null 2>&1
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

group_description() {
  case "$1" in
    users)
      printf '%s\n' "Baseline identity only. Give this to normal people first."
      ;;
    fileshare_users)
      printf '%s\n' "Access to the public Files site through OAuth2 Proxy."
      ;;
    immich-users)
      printf '%s\n' "Can sign into Photos / Immich."
      ;;
    immich-admin)
      printf '%s\n' "Intended Photos admin. Also grants Photos login."
      ;;
    paperless-users)
      printf '%s\n' "Can sign into Paperless."
      ;;
    paperless-admin)
      printf '%s\n' "Intended Paperless admin. Also grants Paperless login."
      ;;
    audiobookshelf-users)
      printf '%s\n' "Can sign into Audiobookshelf."
      ;;
    audiobookshelf-admin)
      printf '%s\n' "Intended Audiobookshelf admin. Also grants login."
      ;;
    kavita-login)
      printf '%s\n' "Can sign into Books / Kavita."
      ;;
    kavita-admin)
      printf '%s\n' "Books / Kavita admin. Also grants Kavita login."
      ;;
    idm_admins)
      printf '%s\n' "Delegated Kanidm admin. Only grant to trusted operators."
      ;;
    *)
      printf '%s\n' "${GROUP_DESCRIPTIONS[$1]:-Advanced or system group. Use only if you know why.}"
      ;;
  esac
}

is_core_group() {
  case "$1" in
    users|fileshare_users|immich-users|immich-admin|paperless-users|paperless-admin|audiobookshelf-users|audiobookshelf-admin|kavita-login|kavita-admin|idm_admins)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
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

dialog_menu_with_help() {
  local title="$1"
  local prompt="$2"
  shift 2
  local status=0
  local result

  if ! result="$(
    dialog \
      --title "$title" \
      --item-help \
      --menu "$prompt" 24 110 14 \
      "$@" \
      --output-fd 3 \
      3>&1 1>&2 2>&3
  )"; then
    status=$?
  fi

  restore_terminal
  [[ "$status" -eq 0 ]] || return "$status"
  printf '%s\n' "$result"
}

group_selected() {
  local needle="$1"
  shift || true
  printf '%s\n' "$@" | grep -Fxq "$needle"
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

last_json_output() {
  printf '%s\n' "$LAST_COMMAND_OUTPUT" | sed -n '/^[[:space:]]*[\[{]/,$p'
}

command_needs_login() {
  local text
  text="$(printf '%s' "$LAST_COMMAND_OUTPUT" | tr '[:upper:]' '[:lower:]')"
  [[ "$text" == *"no valid auth tokens found"* ]] \
    || [[ "$text" == *"session has expired"* ]] \
    || [[ "$text" == *"login again"* ]]
}

command_needs_reauth() {
  local text
  text="$(printf '%s' "$LAST_COMMAND_OUTPUT" | tr '[:upper:]' '[:lower:]')"
  [[ "$text" == *"privileges have expired"* ]] \
    || [[ "$text" == *"privileges have not been re-authenticated"* ]] \
    || [[ "$text" == *"need to re-authenticate again"* ]]
}

run_kanidm_capture() {
  local context="$1"
  shift
  local retried_login=0
  local retried_reauth=0

  while true; do
    run_command_capture "$@"

    if [[ "$LAST_COMMAND_STATUS" -eq 0 ]]; then
      return 0
    fi

    if command_needs_login && [[ "$retried_login" -eq 0 ]]; then
      retried_login=1
      msg_box "Authentication Required" \
        "$context needs an authenticated Kanidm CLI session.

The TUI will now open 'kanidm login' in the terminal below this window."
      login_flow --quiet || return 0
      continue
    fi

    if command_needs_reauth && [[ "$retried_reauth" -eq 0 ]]; then
      retried_reauth=1
      msg_box "Reauthentication Required" \
        "$context needs privileged Kanidm admin access.

The TUI will now open 'kanidm reauth' in the terminal below this window."
      reauth_flow --quiet || return 0
      continue
    fi

    return 0
  done
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

fetch_group_names() {
  local line name description
  local core_groups=(
    users
    fileshare_users
    immich-users
    immich-admin
    paperless-users
    paperless-admin
    audiobookshelf-users
    audiobookshelf-admin
    kavita-login
    kavita-admin
    idm_admins
  )

  GROUP_NAMES=()
  GROUP_DESCRIPTIONS=()

  run_kanidm_capture "Loading the current Kanidm groups" \
    kanidm group list --url "$SERVER_URL" --name "$ADMIN_NAME" -o json
  require_success "Group List" "Could not read groups from Kanidm." || return 1

  while IFS= read -r line; do
    name="$(jq -r '.name' <<<"$line")"
    description="$(jq -r '.description' <<<"$line")"
    [[ -n "$name" && "$name" != "null" ]] || continue
    GROUP_DESCRIPTIONS["$name"]="$description"
  done < <(jq -rc '.[] | { name: (.name[0] // ""), description: (.description[0] // "") }' <<<"$(last_json_output)")

  for name in "${core_groups[@]}"; do
    if [[ -n "${GROUP_DESCRIPTIONS[$name]+x}" ]]; then
      GROUP_NAMES+=("$name")
    fi
  done
}

fetch_person_names() {
  run_kanidm_capture "Loading the current Kanidm users" \
    kanidm person list --url "$SERVER_URL" --name "$ADMIN_NAME" -o json
  require_success "Person List" "Could not read users from Kanidm." || return 1
  mapfile -t PERSON_NAMES < <(
    jq -r '.[] | (.name[0] // empty)' <<<"$(last_json_output)" \
      | awk 'NF && !seen[$0]++'
  )
}

fetch_user_core_groups() {
  local account_id="$1"

  CURRENT_USER_GROUPS=()

  run_kanidm_capture "Loading the current group membership for '$account_id'" \
    kanidm person get "$account_id" --url "$SERVER_URL" --name "$ADMIN_NAME" -o json
  require_success "User Groups" "Could not read the current groups for '$account_id'." || return 1

  mapfile -t CURRENT_USER_GROUPS < <(
    jq -r '
      if type == "array" then .[] else (.attrs // .) end
      | (.directmemberof // [])
      | .[]
    ' <<<"$(last_json_output)" \
      | sed 's/@.*$//' \
      | awk 'NF && !seen[$0]++' \
      | while IFS= read -r group_name; do
          if is_core_group "$group_name"; then
            printf '%s\n' "$group_name"
          fi
        done
  )
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
    items_ref+=("$value" "$(group_description "$value")" OFF)
  done
}

group_item_text() {
  case "$1" in
    users) printf '%s\n' "Baseline identity" ;;
    fileshare_users) printf '%s\n' "Files access" ;;
    immich-users) printf '%s\n' "Photos login" ;;
    immich-admin) printf '%s\n' "Photos admin" ;;
    paperless-users) printf '%s\n' "Paperless login" ;;
    paperless-admin) printf '%s\n' "Paperless admin" ;;
    audiobookshelf-users) printf '%s\n' "Audiobookshelf login" ;;
    audiobookshelf-admin) printf '%s\n' "Audiobookshelf admin" ;;
    kavita-login) printf '%s\n' "Books login" ;;
    kavita-admin) printf '%s\n' "Books admin" ;;
    idm_admins) printf '%s\n' "Kanidm delegated admin" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

confirm_create_user() {
  local account_id="$1"
  local response

  response="$(input_box "Final Confirmation" "Type CREATE to create '$account_id'.

This is the last step before anything is written to Kanidm.
Leave this blank or press Cancel to stop." "")" || return 1

  [[ "$response" == "CREATE" ]]
}

refresh_auth_state() {
  local status

  set +e
  kanidm session list --url "$SERVER_URL" --name "$ADMIN_NAME" >/dev/null 2>&1
  status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    AUTH_STATUS="Authenticated"
    AUTH_HINT="A valid Kanidm CLI session is present for '$ADMIN_NAME'. Some admin actions may still prompt for reauthentication."
  else
    AUTH_STATUS="Login required"
    AUTH_HINT="Only Authenticate, Settings, and Exit are available until login succeeds."
  fi
}

show_auth_status_flow() {
  run_kanidm_capture "Checking the current Kanidm CLI session" \
    kanidm session list --url "$SERVER_URL" --name "$ADMIN_NAME"

  if [[ "$LAST_COMMAND_STATUS" -eq 0 ]]; then
    show_command_result "Authentication Status" \
      "A valid admin CLI session is active for '$ADMIN_NAME'."
  else
    show_command_result "Authentication Status" \
      "No valid admin CLI session is active for '$ADMIN_NAME'. Authenticate before using create, view, group, or password reset actions."
  fi
}

ensure_authenticated() {
  local context="$1"
  refresh_auth_state
  if [[ "$AUTH_STATUS" == "Authenticated" ]]; then
    return 0
  fi

  msg_box "Authentication Required" \
    "$context needs an authenticated Kanidm CLI session.

The next step opens 'kanidm login' in the terminal below this window.
Enter your Kanidm password there."

  login_flow --quiet || return 1
  refresh_auth_state
  if [[ "$AUTH_STATUS" != "Authenticated" ]]; then
    error_box "Authentication Required" "The Kanidm CLI session is still not authenticated."
    return 1
  fi
}

choose_person() {
  local title="$1"
  local prompt="$2"
  local manual_choice="__manual__"
  local choice
  local menu_items
  local menu_items_existing=()

  fetch_person_names || return 1

  menu_items=("$manual_choice" "Type an account id manually")
  if [[ "${#PERSON_NAMES[@]}" -gt 0 ]]; then
    list_to_menu_items PERSON_NAMES menu_items_existing
    menu_items+=("${menu_items_existing[@]}")
  fi

  choice="$(menu_box "$title" "$prompt" "${menu_items[@]}")" || return 1

  if [[ "$choice" == "$manual_choice" ]]; then
    choice="$(input_box "$title" "Enter the Kanidm account id to manage.")" || return 1
  fi

  choice="$(trim "$choice")"
  [[ -n "$choice" ]] || return 1
  printf '%s\n' "$choice"
}

edit_group_selection() {
  local title="$1"
  local prompt="$2"
  local choice
  local group_name
  local item_text
  local index
  local menu_items=()
  local simple_items=()
  local working_groups=("${CURRENT_USER_GROUPS[@]}")

  fetch_group_names || return 1

  if [[ "${#GROUP_NAMES[@]}" -eq 0 ]]; then
    SELECTED_GROUPS=()
    msg_box "$title" "None of the expected access groups were returned by Kanidm."
    return 0
  fi

  while true; do
    menu_items=()
    for group_name in "${GROUP_NAMES[@]}"; do
      item_text="$(group_item_text "$group_name")"
      if group_selected "$group_name" "${working_groups[@]}"; then
        menu_items+=("$group_name" "[x] $item_text" "$(group_description "$group_name")")
      else
        menu_items+=("$group_name" "[ ] $item_text" "$(group_description "$group_name")")
      fi
    done
    menu_items+=("__apply__" "Apply selected groups" "Write the selected groups shown above")
    menu_items+=("__cancel__" "Cancel without saving" "Leave group membership unchanged")

    if require_cmd_optional dialog; then
      choice="$(dialog_menu_with_help "$title" "$prompt" "${menu_items[@]}")" || return 1
    else
      simple_items=()
      for ((index = 0; index < ${#menu_items[@]}; index += 3)); do
        simple_items+=("${menu_items[index]}" "${menu_items[index + 1]}")
      done
      choice="$(menu_box "$title" "$prompt" "${simple_items[@]}")" || return 1
    fi

    case "$choice" in
      __apply__)
        break
        ;;
      __cancel__)
        return 1
        ;;
      *)
        if group_selected "$choice" "${working_groups[@]}"; then
          mapfile -t working_groups < <(
            printf '%s\n' "${working_groups[@]}" | awk -v target="$choice" '$0 != target'
          )
        elif is_core_group "$choice"; then
          working_groups+=("$choice")
        fi
        ;;
    esac
  done

  SELECTED_GROUPS=()
  for group_name in "${GROUP_NAMES[@]}"; do
    if group_selected "$group_name" "${working_groups[@]}"; then
      SELECTED_GROUPS+=("$group_name")
    fi
  done
}

choose_groups() {
  local title="$1"
  local prompt="$2"
  CURRENT_USER_GROUPS=()
  edit_group_selection "$title" "$prompt" || return 1
}

toggle_groups_for_user() {
  local account_id="$1"
  local prompt="$2"
  fetch_user_core_groups "$account_id" || return 1
  edit_group_selection "Group Membership" "$prompt" || return 1
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

login_flow() {
  local quiet=0
  [[ "${1:-}" == "--quiet" ]] && quiet=1

  if [[ "$quiet" -eq 0 ]]; then
    msg_box "Authenticate" "This opens 'kanidm login' in the terminal below this window.

Use this first when the TUI says Login required.
You will type your Kanidm password in the terminal prompt, not in the dialog."
  fi
  run_command_interactive kanidm login --url "$SERVER_URL" --name "$ADMIN_NAME"
  refresh_auth_state
  if [[ "$quiet" -eq 0 ]]; then
    if [[ "$AUTH_STATUS" == "Authenticated" ]]; then
      msg_box "Authenticate" "Authentication succeeded for '$ADMIN_NAME'."
    else
      show_command_result "Authenticate" "The login attempt finished, but the TUI still could not confirm an active CLI session."
    fi
  fi
}

reauth_flow() {
  local quiet=0
  [[ "${1:-}" == "--quiet" ]] && quiet=1

  if [[ "$quiet" -eq 0 ]]; then
    msg_box "Reauthenticate" "This opens 'kanidm reauth' in the terminal below this window.

Use this when privileged admin actions say reauthentication is required."
  fi
  run_command_interactive kanidm reauth --url "$SERVER_URL" --name "$ADMIN_NAME"
  if [[ "$quiet" -eq 0 ]]; then
    show_command_result "Reauthenticate" "The privileged reauthentication attempt has finished."
  fi
}

list_people_flow() {
  local rows body

  run_kanidm_capture "Listing Kanidm users" \
    kanidm person list --url "$SERVER_URL" --name "$ADMIN_NAME" -o json
  require_success "Kanidm Users" "Could not read users from Kanidm." || return 1

  rows="$(
    jq -r '.[] | [(.name[0] // "-"), (.displayname[0] // "-"), (.mail[0] // "-")] | @tsv' <<<"$(last_json_output)" \
      | while IFS=$'\t' read -r account_id display_name primary_email; do
          printf '%-18s %-24s %s\n' "$account_id" "$display_name" "$primary_email"
        done
  )"

  body="$(printf '%-18s %-24s %s\n' "ACCOUNT ID" "DISPLAY NAME" "PRIMARY EMAIL")"
  if [[ -n "$rows" ]]; then
    body+=$'\n'"$rows"
  fi

  show_text_block "Kanidm Users" "$body"
}

view_person_flow() {
  local account_id
  local body
  local row
  local core_group_text="(none)"
  account_id="$(choose_person "View User" "Select a Kanidm user to inspect.")" || return 1
  run_kanidm_capture "Loading the selected user record" \
    kanidm person get "$account_id" --url "$SERVER_URL" --name "$ADMIN_NAME" -o json
  require_success "User Detail" "Could not load '$account_id'." || return 1

  mapfile -t CURRENT_USER_GROUPS < <(
    jq -r '
      if type == "array" then .[] else (.attrs // .) end
      | (.directmemberof // [])
      | .[]
    ' <<<"$(last_json_output)" \
      | sed 's/@.*$//' \
      | awk 'NF && !seen[$0]++' \
      | while IFS= read -r group_name; do
          if is_core_group "$group_name"; then
            printf '%s\n' "$group_name"
          fi
        done
  )

  if [[ "${#CURRENT_USER_GROUPS[@]}" -gt 0 ]]; then
    core_group_text=""
    for row in "${CURRENT_USER_GROUPS[@]}"; do
      core_group_text+="  - $row"$'\n'
    done
    core_group_text="${core_group_text%$'\n'}"
  fi

  body="$(jq -r '
    if type == "array" then .[] else (.attrs // .) end
    | "Account ID: \(.name[0] // "-")\nDisplay Name: \(.displayname[0] // "-")\nPrimary Email: \(.mail[0] // "-")\nSPN: \(.spn[0] // "-")\nUUID: \(.uuid[0] // "-")\nValid From: \(.account_valid_from[0] // "not set")\nExpiry Date: \(.account_expire[0] // "not set")\n"
  ' <<<"$(last_json_output)")"
  body+=$'\n'"Common access groups:"$'\n'"$core_group_text"

  show_text_block "User Detail" "$body"
}

create_user_flow() {
  local account_id display_name primary_email summary group_lines=""

  account_id="$(input_box "Create User" "New account id / username.")" || return 1
  [[ -n "$account_id" ]] || return 1

  display_name="$(input_box "Create User" "Display name for '$account_id'.")" || return 1
  [[ -n "$display_name" ]] || return 1

  primary_email="$(input_box "Create User" "Primary email. Leave blank to skip." "")" || return 1

  choose_groups \
    "Create User" \
    "Select common groups for this person.

Recommended:
- Give normal people 'users'
- Add only the app login groups they actually need
- Add admin groups only for trusted app administrators

Choose a group to toggle it.
Use 'Apply selected groups' when the list is correct.

These are the only groups shown here on purpose." || return 1

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
$group_lines"

  show_text_block "Create User Summary" "$summary"
  confirm_create_user "$account_id" || {
    msg_box "Create User" "Creation cancelled. No changes were made."
    return 0
  }

  run_kanidm_capture "Creating the new Kanidm user" \
    kanidm person create "$account_id" "$display_name" --url "$SERVER_URL" --name "$ADMIN_NAME"
  require_success "Create User" "User creation failed." || return 1

  run_kanidm_capture "Clearing any unexpected expiry on the new user" \
    kanidm person validity expire-at "$account_id" clear --url "$SERVER_URL" --name "$ADMIN_NAME"
  require_success "Clear Expiry" "User was created, but clearing the expiry date failed." || return 1

  run_kanidm_capture "Clearing any unexpected valid-from restriction on the new user" \
    kanidm person validity begin-from "$account_id" clear --url "$SERVER_URL" --name "$ADMIN_NAME"
  require_success "Clear Valid-From" "User was created, but clearing the valid-from date failed." || return 1

  if [[ -n "$primary_email" ]]; then
    run_kanidm_capture "Setting the user's primary email" \
      kanidm person update "$account_id" --mail "$primary_email" --url "$SERVER_URL" --name "$ADMIN_NAME"
    require_success "Set Email" "User was created, but setting the primary email failed." || return 1
  fi

  if [[ "${#SELECTED_GROUPS[@]}" -gt 0 ]]; then
    local group_name
    for group_name in "${SELECTED_GROUPS[@]}"; do
      run_kanidm_capture "Adding the user to '$group_name'" \
        kanidm group add-members "$group_name" "$account_id" --url "$SERVER_URL" --name "$ADMIN_NAME"
        require_success "Add Group" "User was created, but adding '$account_id' to '$group_name' failed." || return 1
    done
  fi

  run_kanidm_capture "Loading the final user record" \
    kanidm person get "$account_id" --url "$SERVER_URL" --name "$ADMIN_NAME"
  show_command_result "User Created" "Final record for '$account_id'."
}

group_membership_flow() {
  local account_id group_name
  local added=()
  local removed=()
  local before_groups=()
  local after_groups=()
  local summary
  account_id="$(choose_person "Group Membership" "Select a Kanidm user to change group membership for.")" || return 1

  fetch_user_core_groups "$account_id" || return 1
  before_groups=("${CURRENT_USER_GROUPS[@]}")

  toggle_groups_for_user "$account_id" "Choose a group to toggle membership for '$account_id'.\n\nThe highlighted group's help appears at the bottom.\nUse 'Apply selected groups' when the final state is correct." || return 1
  after_groups=("${SELECTED_GROUPS[@]}")

  for group_name in "${after_groups[@]}"; do
    if ! printf '%s\n' "${before_groups[@]}" | grep -Fxq "$group_name"; then
      added+=("$group_name")
    fi
  done

  for group_name in "${before_groups[@]}"; do
    if ! printf '%s\n' "${after_groups[@]}" | grep -Fxq "$group_name"; then
      removed+=("$group_name")
    fi
  done

  if [[ "${#added[@]}" -eq 0 && "${#removed[@]}" -eq 0 ]]; then
    msg_box "Group Membership" "No membership changes were selected for '$account_id'."
    return 0
  fi

  for group_name in "${added[@]}"; do
    run_kanidm_capture "Adding '$account_id' to '$group_name'" \
      kanidm group add-members "$group_name" "$account_id" --url "$SERVER_URL" --name "$ADMIN_NAME"
    require_success "Add Group" "Adding '$account_id' to '$group_name' failed." || return 1
  done

  for group_name in "${removed[@]}"; do
    run_kanidm_capture "Removing '$account_id' from '$group_name'" \
      kanidm group remove-members "$group_name" "$account_id" --url "$SERVER_URL" --name "$ADMIN_NAME"
    require_success "Remove Group" "Removing '$account_id' from '$group_name' failed." || return 1
  done

  fetch_user_core_groups "$account_id" || return 1
  summary="Updated groups for '$account_id'."
  if [[ "${#added[@]}" -gt 0 ]]; then
    summary+=$'\n\nAdded:'
    for group_name in "${added[@]}"; do
      summary+=$'\n'"  - $group_name"
    done
  fi
  if [[ "${#removed[@]}" -gt 0 ]]; then
    summary+=$'\n\nRemoved:'
    for group_name in "${removed[@]}"; do
      summary+=$'\n'"  - $group_name"
    done
  fi
  summary+=$'\n\nCurrent managed groups:'
  if [[ "${#CURRENT_USER_GROUPS[@]}" -gt 0 ]]; then
    for group_name in "${CURRENT_USER_GROUPS[@]}"; do
      summary+=$'\n'"  - $group_name"
    done
  else
    summary+=$'\n'"  (none)"
  fi

  show_text_block "Group Membership" "$summary"
}

password_reset_flow() {
  local account_id
  local ttl

  account_id="$(choose_person "Password Reset" "Select a Kanidm user to generate a password reset token for.")" || return 1

  ttl="$(input_box "Password Reset" "Reset token lifetime in seconds.\n\nUse 3600 for one hour or 86400 for one day.\nLeave blank to use the default of 3600 seconds." "3600")" || return 1
  ttl="${ttl:-3600}"

  if [[ ! "$ttl" =~ ^[0-9]+$ ]]; then
    error_box "Password Reset" "The token lifetime must be a whole number of seconds."
    return 1
  fi

  run_kanidm_capture "Creating a password reset token for '$account_id'" \
    kanidm person credential create-reset-token "$account_id" "$ttl" --url "$SERVER_URL" --name "$ADMIN_NAME"
  require_success "Password Reset" "Could not create a password reset token for '$account_id'." || return 1

  show_command_result "Password Reset Token" \
    "Give this token or link to '$account_id'. It lets that user set or replace their login credential."
}

main_menu() {
  local choice
  while true; do
    refresh_auth_state
    if [[ "$AUTH_STATUS" == "Authenticated" ]]; then
      choice="$(
        menu_box \
          "Kanidm User TUI" \
          "Recommended order:
  1. Authenticate
  2. Create or inspect a user
  3. Add the right access groups

Authentication: $AUTH_STATUS
$AUTH_HINT

Server: $SERVER_URL
Admin: $ADMIN_NAME" \
          auth "Refresh or replace the current Kanidm CLI session" \
          status "Show whether the current admin CLI session is valid" \
          create "Create a new Kanidm person" \
          users "List current users" \
          view "Inspect one user record" \
          groups "Toggle access groups to the desired final state" \
          reset "Create a password reset token for a user" \
          settings "Show connection settings loaded from vars.nix" \
          exit "Exit"
      )" || break
    else
      choice="$(
        menu_box \
          "Kanidm User TUI" \
          "Authentication: $AUTH_STATUS
$AUTH_HINT

Server: $SERVER_URL
Admin: $ADMIN_NAME" \
          auth "Login to Kanidm as the configured admin user" \
          status "Show whether the current admin CLI session is valid" \
          settings "Show connection settings loaded from vars.nix" \
          exit "Exit"
      )" || break
    fi

    case "$choice" in
      auth) login_flow ;;
      status) show_auth_status_flow ;;
      create) ensure_authenticated "Creating a user" && create_user_flow ;;
      users) ensure_authenticated "Listing users" && list_people_flow ;;
      view) ensure_authenticated "Viewing a user record" && view_person_flow ;;
      groups) ensure_authenticated "Managing group membership" && group_membership_flow ;;
      reset) ensure_authenticated "Creating a password reset token" && password_reset_flow ;;
      settings) show_current_settings ;;
      exit) break ;;
    esac
  done
}

require_tty
require_cmd bash
require_cmd kanidm
require_cmd nix
require_cmd jq
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
declare -A GROUP_DESCRIPTIONS=()
AUTH_STATUS="Unknown"
AUTH_HINT=""

main_menu
