use std::{fs, os::unix::fs::PermissionsExt, path::Path, process::Command as ProcessCommand};

use assert_cmd::Command;
use predicates::prelude::*;
use tempfile::TempDir;

fn write_script(path: &Path, body: &str) {
    let shell = ProcessCommand::new("bash")
        .args(["-lc", "command -v bash"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|stdout| stdout.trim().to_string())
        .filter(|stdout| !stdout.is_empty())
        .unwrap_or_else(|| "/bin/sh".to_string());
    let rewritten = body.replacen("#!/usr/bin/env bash", &format!("#!{shell}"), 1);
    fs::write(path, rewritten).expect("write script");
    let mut permissions = fs::metadata(path).expect("metadata").permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).expect("chmod");
}

fn stub_dir(script_body: &str) -> TempDir {
    let dir = tempfile::tempdir().expect("tempdir");
    let script = dir.path().join("kanidm-stub.sh");
    write_script(&script, script_body);
    dir
}

#[test]
fn users_list_outputs_human_table() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "person" && "$2" == "list" ]]; then
  printf '[{"name":["dsaw"],"displayname":["Dan"],"mail":["dsaw@example.test"]}]'
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", dir.path().join("kanidm-stub.sh"))
        .args([
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "users",
            "list",
        ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("ACCOUNT ID"))
        .stdout(predicate::str::contains("dsaw"));
}

#[test]
fn users_list_surfaces_parser_warnings() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "person" && "$2" == "list" ]]; then
  printf '[{"name":["dsaw"],"displayname":["Dan"]},{"displayname":["Missing name"]}]'
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", dir.path().join("kanidm-stub.sh"))
        .args([
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "users",
            "list",
        ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Warnings:"))
        .stdout(predicate::str::contains(
            "skipped malformed Kanidm person list entry",
        ));
}

#[test]
fn access_show_reports_session_required() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
printf 'No valid auth tokens found\n' >&2
exit 1
"#,
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", dir.path().join("kanidm-stub.sh"))
        .args([
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "access",
            "show",
            "dsaw",
        ]);

    cmd.assert().code(6).stderr(predicate::str::contains(
        "Run `kanidm login --url https://id.example.test --name admindsaw` first.",
    ));
}

#[test]
fn users_list_invalid_json_is_reported() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
printf 'not-json'
"#,
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", dir.path().join("kanidm-stub.sh"))
        .args([
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "--format",
            "json",
            "users",
            "list",
        ]);

    cmd.assert()
        .code(9)
        .stderr(predicate::str::contains("\"status\": \"error\""))
        .stderr(predicate::str::contains("invalid JSON"));
}

#[test]
fn auth_login_rejects_json_output_before_spawn() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
echo "unexpected args: $*" >&2
exit 1
"#,
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", dir.path().join("kanidm-stub.sh"))
        .args([
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "--format",
            "json",
            "auth",
            "login",
        ]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("only support --format human"));
}

#[test]
fn auth_login_requires_tty() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
echo "unexpected args: $*" >&2
exit 1
"#,
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", dir.path().join("kanidm-stub.sh"))
        .args([
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "auth",
            "login",
        ]);

    cmd.assert().code(2).stderr(predicate::str::contains(
        "require a terminal on stdin and stdout",
    ));
}

#[test]
fn auth_reauth_rejects_json_output_before_spawn() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
echo "unexpected args: $*" >&2
exit 1
"#,
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", dir.path().join("kanidm-stub.sh"))
        .args([
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "--format",
            "json",
            "auth",
            "reauth",
        ]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("only support --format human"));
}

#[test]
fn users_reset_token_extracts_url_and_token() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "person" && "$2" == "credential" && "$3" == "create-reset-token" ]]; then
  printf 'Reset token: abc123\nUse this link: https://id.example.test/ui/reset?token=abc123\n'
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", dir.path().join("kanidm-stub.sh"))
        .args([
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "users",
            "reset-token",
            "dsaw",
            "--ttl",
            "3600",
        ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains(
            "Reset URL: https://id.example.test/ui/reset?token=abc123",
        ))
        .stdout(predicate::str::contains("Token: abc123"));
}

#[test]
fn users_reset_token_warns_when_output_is_partial() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "person" && "$2" == "credential" && "$3" == "create-reset-token" ]]; then
  printf 'Reset token: abc123\n'
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", dir.path().join("kanidm-stub.sh"))
        .args([
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "users",
            "reset-token",
            "dsaw",
            "--ttl",
            "3600",
        ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Token: abc123"))
        .stdout(predicate::str::contains("Warnings:"))
        .stdout(predicate::str::contains("did not contain a reset URL"));
}

#[test]
fn access_grant_retries_until_group_membership_is_visible() {
    let dir = tempfile::tempdir().expect("tempdir");
    let attempts_path = dir.path().join("attempts");
    let script_body = format!(
        r#"#!/usr/bin/env bash
set -euo pipefail
attempts_path="{attempts_path}"
current_attempts=0
if [[ -f "$attempts_path" ]]; then
  current_attempts="$(cat "$attempts_path")"
fi

if [[ "$1" == "group" && "$2" == "add-members" ]]; then
  echo 0 > "$attempts_path"
  exit 0
fi

if [[ "$1" == "person" && "$2" == "get" ]]; then
  current_attempts=$((current_attempts + 1))
  echo "$current_attempts" > "$attempts_path"
  if [[ "$current_attempts" -ge 3 ]]; then
    printf '{{"attrs":{{"name":["dsaw"],"directmemberof":["users@example.test"]}}}}'
  else
    printf '{{"attrs":{{"name":["dsaw"],"directmemberof":[]}}}}'
  fi
  exit 0
fi

echo "unexpected args: $*" >&2
exit 1
"#,
        attempts_path = attempts_path.display()
    );
    let script = dir.path().join("kanidm-stub.sh");
    write_script(&script, &script_body);

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", &script).args([
        "--server-url",
        "https://id.example.test",
        "--admin-name",
        "admindsaw",
        "access",
        "grant",
        "dsaw",
        "users",
    ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Granted 'users' to 'dsaw'"));
}

#[test]
fn access_set_updates_authoritative_managed_groups() {
    let dir = tempfile::tempdir().expect("tempdir");
    let groups_path = dir.path().join("groups");
    fs::write(&groups_path, "users\nimmich-users\n").expect("seed groups");
    let script_body = format!(
        r#"#!/usr/bin/env bash
set -euo pipefail
groups_path="{groups_path}"

read_groups() {{
  if [[ -f "$groups_path" ]]; then
    cat "$groups_path"
  fi
}}

write_groups() {{
  printf '%s' "$1" > "$groups_path"
}}

if [[ "$1" == "person" && "$2" == "get" ]]; then
  mapfile -t groups < <(read_groups)
  printf '{{"attrs":{{"name":["dsaw"],"directmemberof":['
  first=1
  for group in "${{groups[@]}}"; do
    [[ -n "$group" ]] || continue
    if [[ $first -eq 0 ]]; then printf ','; fi
    printf '"%s@example.test"' "$group"
    first=0
  done
  printf ']}}}}'
  exit 0
fi

if [[ "$1" == "group" && "$2" == "add-members" ]]; then
  mapfile -t groups < <(read_groups)
  groups+=("$3")
  printf '%s\n' "${{groups[@]}}" | awk 'NF' | sort -u > "$groups_path"
  exit 0
fi

if [[ "$1" == "group" && "$2" == "remove-members" ]]; then
  mapfile -t groups < <(read_groups)
  : > "$groups_path"
  for group in "${{groups[@]}}"; do
    if [[ "$group" != "$3" && -n "$group" ]]; then
      printf '%s\n' "$group" >> "$groups_path"
    fi
  done
  exit 0
fi

echo "unexpected args: $*" >&2
exit 1
"#,
        groups_path = groups_path.display()
    );
    let script = dir.path().join("kanidm-stub.sh");
    write_script(&script, &script_body);

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", &script).args([
        "--server-url",
        "https://id.example.test",
        "--admin-name",
        "admindsaw",
        "access",
        "set",
        "dsaw",
        "--group",
        "users",
        "--group",
        "paperless-users",
    ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Added:"))
        .stdout(predicate::str::contains("paperless-users"))
        .stdout(predicate::str::contains("Removed:"))
        .stdout(predicate::str::contains("immich-users"));
}

#[test]
fn access_set_rejects_empty_without_allow_empty() {
    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.args([
        "--server-url",
        "https://id.example.test",
        "--admin-name",
        "admindsaw",
        "access",
        "set",
        "dsaw",
    ]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("requires --allow-empty"));
}

#[test]
fn access_grant_rejects_unknown_group() {
    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.args([
        "--server-url",
        "https://id.example.test",
        "--admin-name",
        "admindsaw",
        "access",
        "grant",
        "dsaw",
        "idm_admins",
    ]);

    cmd.assert()
        .code(4)
        .stderr(predicate::str::contains("invalid managed group"));
}

#[test]
fn users_delete_requires_matching_confirm_value() {
    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.args([
        "--server-url",
        "https://id.example.test",
        "--admin-name",
        "admindsaw",
        "users",
        "delete",
        "dsaw",
        "--confirm",
        "wrong",
    ]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("requires --confirm dsaw"));
}

#[test]
fn users_delete_verifies_account_disappears() {
    let dir = tempfile::tempdir().expect("tempdir");
    let deleted_path = dir.path().join("deleted");
    let script_body = format!(
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "person" && "$2" == "delete" ]]; then
  touch "{deleted_path}"
  exit 0
fi
if [[ "$1" == "person" && "$2" == "get" ]]; then
  if [[ -e "{deleted_path}" ]]; then
    printf '[]'
  else
    printf '{{"attrs":{{"name":["dsaw"]}}}}'
  fi
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
        deleted_path = deleted_path.display()
    );
    let script = dir.path().join("kanidm-stub.sh");
    write_script(&script, &script_body);

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", &script).args([
        "--server-url",
        "https://id.example.test",
        "--admin-name",
        "admindsaw",
        "users",
        "delete",
        "dsaw",
        "--confirm",
        "dsaw",
    ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Deleted Kanidm user 'dsaw'."));
}

#[test]
fn jellyfin_set_password_writes_hash_file() {
    let dir = tempfile::tempdir().expect("tempdir");

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_JELLYFIN_PASSWORD_HASH_DIR", dir.path())
        .env("TEST_JELLYFIN_PASSWORD", "super-secret")
        .args([
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "jellyfin",
            "set-password",
            "dsaw",
            "--password-env",
            "TEST_JELLYFIN_PASSWORD",
        ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains(
            "Staged the desired Jellyfin password hash",
        ))
        .stdout(predicate::str::contains("still needs to apply"));

    let written = fs::read_to_string(dir.path().join("dsaw.pbkdf2")).expect("hash file");
    assert!(written.starts_with("$PBKDF2-SHA512$iterations=210000$"));
}
