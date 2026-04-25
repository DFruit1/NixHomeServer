use std::{fs, os::unix::fs::PermissionsExt, path::Path};

use assert_cmd::Command;
use predicates::prelude::*;
use tempfile::TempDir;

fn write_script(path: &Path, body: &str) {
    fs::write(path, body).expect("write script");
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
fn auth_login_verifies_session_after_success() {
    let dir = tempfile::tempdir().expect("tempdir");
    let state_path = dir.path().join("logged-in");
    let script_body = format!(
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "login" ]]; then
  touch "{state_path}"
  exit 0
fi
if [[ "$1" == "session" && "$2" == "list" ]]; then
  if [[ -e "{state_path}" ]]; then
    printf 'session active\n'
    exit 0
  fi
fi
echo "unexpected args: $*" >&2
exit 1
"#,
        state_path = state_path.display()
    );
    let script = dir.path().join("kanidm-stub.sh");
    write_script(&script, &script_body);

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", &script).args([
        "--server-url",
        "https://id.example.test",
        "--admin-name",
        "admindsaw",
        "auth",
        "login",
    ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Authentication succeeded"));
}

#[test]
fn auth_reauth_reports_success() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "reauth" ]]; then
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
            "auth",
            "reauth",
        ]);

    cmd.assert().success().stdout(predicate::str::contains(
        "Privileged Kanidm access was refreshed",
    ));
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
