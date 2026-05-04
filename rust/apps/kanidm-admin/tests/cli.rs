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
fn user_list_outputs_human_table() {
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
            "user",
            "list",
        ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("ACCOUNT ID"))
        .stdout(predicate::str::contains("dsaw"));
}

#[test]
fn session_login_rejects_json_output_before_spawn() {
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
            "--output",
            "json",
            "session",
            "login",
        ]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("only support --output human"));
}

#[test]
fn membership_set_rejects_empty_without_allow_empty() {
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
            "membership",
            "set",
            "dsaw",
        ]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("requires --allow-empty"));
}

#[test]
fn membership_add_requires_at_least_one_group() {
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
            "membership",
            "add",
            "dsaw",
        ]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("<GROUPS>..."));
}

#[test]
fn membership_remove_requires_at_least_one_group() {
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
            "membership",
            "remove",
            "dsaw",
        ]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("<GROUPS>..."));
}

#[test]
fn membership_add_accepts_brand_new_live_group() {
    let dir = tempfile::tempdir().expect("tempdir");
    fs::write(dir.path().join("groups.txt"), "").expect("seed groups");
    let script = dir.path().join("kanidm-stub.sh");
    write_script(
        &script,
        &format!(
            r#"#!/usr/bin/env bash
set -euo pipefail
state_dir={}
groups_file="$state_dir/groups.txt"
args=("$@")
if [[ "${{args[0]}}" == "group" && "${{args[1]}}" == "get" && "${{args[2]}}" == "brand-new-group" ]]; then
  printf '{{"attrs":{{"name":["brand-new-group"],"description":["New group"]}}}}'
  exit 0
fi
if [[ "${{args[0]}}" == "group" && "${{args[1]}}" == "add-members" && "${{args[2]}}" == "brand-new-group" && "${{args[3]}}" == "dsaw" ]]; then
  printf 'brand-new-group\n' >> "$groups_file"
  exit 0
fi
if [[ "${{args[0]}}" == "person" && "${{args[1]}}" == "get" && "${{args[2]}}" == "dsaw" ]]; then
  mapfile -t groups < "$groups_file"
  if [[ ${{#groups[@]}} -eq 0 ]]; then
    printf '{{"attrs":{{"name":["dsaw"],"displayname":["Dan"],"directmemberof":[]}}}}'
  else
    printf '{{"attrs":{{"name":["dsaw"],"displayname":["Dan"],"directmemberof":["brand-new-group@example.test"]}}}}'
  fi
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
            serde_json::to_string(&dir.path().display().to_string()).expect("json path"),
        ),
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", &script).args([
        "--server-url",
        "https://id.example.test",
        "--admin-name",
        "admindsaw",
        "membership",
        "add",
        "dsaw",
        "brand-new-group",
    ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("brand-new-group"));
}

#[test]
fn client_list_discovers_brand_new_client() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "system" && "$2" == "oauth2" && "$3" == "list" ]]; then
  printf '[{"name":["brand-new-client"],"displayname":["Brand New"],"landing":["https://app.example.test"]}]'
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
            "client",
            "list",
        ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("brand-new-client"));
}

#[test]
fn client_show_discovers_brand_new_client() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "system" && "$2" == "oauth2" && "$3" == "get" && "$4" == "brand-new-client" ]]; then
  printf '{"attrs":{"name":["brand-new-client"],"displayname":["Brand New"],"landing":["https://app.example.test"]},"scope_maps":{"new-group":["openid","profile"]},"claim_maps":{"new-group":{"role":["reader"]}},"redirect_urls":["https://app.example.test/oauth2/callback"],"disable_pkce":[false],"disable_consent_prompt":[false]}'
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
            "client",
            "show",
            "brand-new-client",
        ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("new-group"))
        .stdout(predicate::str::contains("brand-new-client"));
}

#[test]
fn client_redirect_add_verifies_live_state() {
    let dir = tempfile::tempdir().expect("tempdir");
    fs::write(dir.path().join("redirects.txt"), "").expect("seed redirects");
    let script = dir.path().join("kanidm-stub.sh");
    write_script(
        &script,
        &format!(
            r#"#!/usr/bin/env bash
set -euo pipefail
state_dir={}
redirects_file="$state_dir/redirects.txt"
args=("$@")
if [[ "${{args[0]}}" == "system" && "${{args[1]}}" == "oauth2" && "${{args[2]}}" == "add-redirect-url" ]]; then
  printf '%s\n' "${{args[4]}}" >> "$redirects_file"
  exit 0
fi
if [[ "${{args[0]}}" == "system" && "${{args[1]}}" == "oauth2" && "${{args[2]}}" == "get" ]]; then
  mapfile -t redirects < "$redirects_file"
  if [[ ${{#redirects[@]}} -eq 0 ]]; then
    printf '{{"attrs":{{"name":["files"],"displayname":["Files"],"landing":["https://files.example.test"]}},"redirect_urls":[]}}'
  else
    printf '{{"attrs":{{"name":["files"],"displayname":["Files"],"landing":["https://files.example.test"]}},"redirect_urls":["%s"]}}' "${{redirects[0]}}"
  fi
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
            serde_json::to_string(&dir.path().display().to_string()).expect("json path"),
        ),
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", &script).args([
        "--server-url",
        "https://id.example.test",
        "--admin-name",
        "admindsaw",
        "client",
        "redirect",
        "add",
        "files",
        "https://files.example.test/oauth2/callback",
    ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("oauth2/callback"));
}

#[test]
fn client_pkce_disable_verifies_live_state() {
    let dir = tempfile::tempdir().expect("tempdir");
    fs::write(dir.path().join("pkce.txt"), "true\n").expect("seed pkce");
    let script = dir.path().join("kanidm-stub.sh");
    write_script(
        &script,
        &format!(
            r#"#!/usr/bin/env bash
set -euo pipefail
state_dir={}
pkce_file="$state_dir/pkce.txt"
args=("$@")
if [[ "${{args[0]}}" == "system" && "${{args[1]}}" == "oauth2" && "${{args[2]}}" == "warning-insecure-client-disable-pkce" ]]; then
  printf 'false\n' > "$pkce_file"
  exit 0
fi
if [[ "${{args[0]}}" == "system" && "${{args[1]}}" == "oauth2" && "${{args[2]}}" == "get" ]]; then
  pkce="$(<"$pkce_file")"
  if [[ "$pkce" == "true" ]]; then
    printf '{{"attrs":{{"name":["files"],"displayname":["Files"]}},"disable_pkce":[false]}}'
  else
    printf '{{"attrs":{{"name":["files"],"displayname":["Files"]}},"disable_pkce":[true]}}'
  fi
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
            serde_json::to_string(&dir.path().display().to_string()).expect("json path"),
        ),
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", &script).args([
        "--server-url",
        "https://id.example.test",
        "--admin-name",
        "admindsaw",
        "client",
        "pkce",
        "disable",
        "files",
    ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("PKCE Enabled: no"));
}

#[test]
fn policy_auth_expiry_set_verifies_live_state() {
    let dir = tempfile::tempdir().expect("tempdir");
    fs::write(dir.path().join("auth_expiry.txt"), "").expect("seed auth expiry");
    let script = dir.path().join("kanidm-stub.sh");
    write_script(
        &script,
        &format!(
            r#"#!/usr/bin/env bash
set -euo pipefail
state_dir={}
auth_file="$state_dir/auth_expiry.txt"
args=("$@")
if [[ "${{args[0]}}" == "group" && "${{args[1]}}" == "account-policy" && "${{args[2]}}" == "auth-expiry" ]]; then
  printf '%s\n' "${{args[4]}}" > "$auth_file"
  exit 0
fi
if [[ "${{args[0]}}" == "group" && "${{args[1]}}" == "get" && "${{args[2]}}" == "idm_all_persons" ]]; then
  value="$(<"$auth_file")"
  if [[ -n "$value" ]]; then
    printf '{{"attrs":{{"name":["idm_all_persons"],"auth_expiry":["%s"]}}}}' "$value"
  else
    printf '{{"attrs":{{"name":["idm_all_persons"]}}}}'
  fi
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
            serde_json::to_string(&dir.path().display().to_string()).expect("json path"),
        ),
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", &script).args([
        "--server-url",
        "https://id.example.test",
        "--admin-name",
        "admindsaw",
        "policy",
        "group",
        "auth-expiry",
        "set",
        "idm_all_persons",
        "7200",
    ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Auth Expiry Seconds: 7200"));
}

#[test]
fn doctor_succeeds_with_partial_output_when_inventory_probe_fails() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "session" && "$2" == "list" ]]; then
  printf 'authenticated'
  exit 0
fi
if [[ "$1" == "person" && "$2" == "list" ]]; then
  printf 'backend exploded\n' >&2
  exit 1
fi
if [[ "$1" == "group" && "$2" == "list" ]]; then
  printf '[]'
  exit 0
fi
if [[ "$1" == "system" && "$2" == "oauth2" && "$3" == "list" ]]; then
  printf '[]'
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
            "doctor",
        ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Users: unavailable"))
        .stdout(predicate::str::contains("Errors:"));
}

#[test]
fn doctor_surfaces_session_recovery_guidance() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "session" && "$2" == "list" ]]; then
  printf 'No valid auth tokens found\n' >&2
  exit 1
fi
if [[ "$1" == "person" && "$2" == "list" ]]; then
  printf '[]'
  exit 0
fi
if [[ "$1" == "group" && "$2" == "list" ]]; then
  printf '[]'
  exit 0
fi
if [[ "$1" == "system" && "$2" == "oauth2" && "$3" == "list" ]]; then
  printf '[]'
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
            "doctor",
        ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Run `kanidm-admin session login`"));
}

#[test]
fn session_required_is_reported_on_group_show() {
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
            "group",
            "show",
            "users",
        ]);

    cmd.assert().code(6).stderr(predicate::str::contains(
        "Run `kanidm-admin session login` first.",
    ));
}

#[test]
fn reauth_required_is_reported_on_group_show() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
printf 'must re-authenticate\n' >&2
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
            "group",
            "show",
            "users",
        ]);

    cmd.assert().code(7).stderr(predicate::str::contains(
        "Run `kanidm-admin session reauth` first.",
    ));
}

#[test]
fn group_search_rejects_whitespace_only_query_before_backend() {
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
            "group",
            "search",
            "   ",
        ]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("whitespace only"));
}

#[test]
fn group_search_matches_description_only_queries() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "group" && "$2" == "list" ]]; then
  printf '[{"name":["files-users"],"description":["Personal storage access"]}]'
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
            "group",
            "search",
            "storage",
        ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("files-users"));
}

#[test]
fn group_search_matches_case_insensitively() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "group" && "$2" == "list" ]]; then
  printf '[{"name":["Files-Users"],"description":["Personal Storage Access"]}]'
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
            "group",
            "search",
            "storage",
        ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Files-Users"));
}

#[test]
fn membership_add_downgrades_duplicate_backend_failure_when_state_converged() {
    let dir = tempfile::tempdir().expect("tempdir");
    let script = dir.path().join("kanidm-stub.sh");
    write_script(
        &script,
        r#"#!/usr/bin/env bash
set -euo pipefail
args=("$@")
if [[ "${args[0]}" == "group" && "${args[1]}" == "get" && "${args[2]}" == "users" ]]; then
  printf '{"attrs":{"name":["users"],"description":["Users"]}}'
  exit 0
fi
if [[ "${args[0]}" == "group" && "${args[1]}" == "add-members" ]]; then
  printf 'entry already present\n' >&2
  exit 1
fi
if [[ "${args[0]}" == "person" && "${args[1]}" == "get" && "${args[2]}" == "dsaw" ]]; then
  printf '{"attrs":{"name":["dsaw"],"displayname":["Dan"],"directmemberof":["users@example.test"]}}'
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", &script).args([
        "--server-url",
        "https://id.example.test",
        "--admin-name",
        "admindsaw",
        "membership",
        "add",
        "dsaw",
        "users",
    ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Warnings:"))
        .stdout(predicate::str::contains("group_add_members:users"));
}

#[test]
fn membership_remove_downgrades_absent_backend_failure_when_state_converged() {
    let dir = tempfile::tempdir().expect("tempdir");
    let script = dir.path().join("kanidm-stub.sh");
    write_script(
        &script,
        r#"#!/usr/bin/env bash
set -euo pipefail
args=("$@")
if [[ "${args[0]}" == "group" && "${args[1]}" == "get" && "${args[2]}" == "users" ]]; then
  printf '{"attrs":{"name":["users"],"description":["Users"]}}'
  exit 0
fi
if [[ "${args[0]}" == "group" && "${args[1]}" == "remove-members" ]]; then
  printf 'entry not present\n' >&2
  exit 1
fi
if [[ "${args[0]}" == "person" && "${args[1]}" == "get" && "${args[2]}" == "dsaw" ]]; then
  printf '{"attrs":{"name":["dsaw"],"displayname":["Dan"],"directmemberof":[]}}'
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", &script).args([
        "--server-url",
        "https://id.example.test",
        "--admin-name",
        "admindsaw",
        "membership",
        "remove",
        "dsaw",
        "users",
    ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Warnings:"))
        .stdout(predicate::str::contains("group_remove_members:users"));
}

#[test]
fn client_redirect_add_downgrades_backend_failure_when_state_converged() {
    let dir = tempfile::tempdir().expect("tempdir");
    fs::write(
        dir.path().join("redirects.txt"),
        "https://files.example.test/oauth2/callback\n",
    )
    .expect("seed redirects");
    let script = dir.path().join("kanidm-stub.sh");
    write_script(
        &script,
        &format!(
            r#"#!/usr/bin/env bash
set -euo pipefail
state_dir={}
redirects_file="$state_dir/redirects.txt"
args=("$@")
if [[ "${{args[0]}}" == "system" && "${{args[1]}}" == "oauth2" && "${{args[2]}}" == "add-redirect-url" ]]; then
  printf 'redirect already present\n' >&2
  exit 1
fi
if [[ "${{args[0]}}" == "system" && "${{args[1]}}" == "oauth2" && "${{args[2]}}" == "get" ]]; then
  mapfile -t redirects < "$redirects_file"
  printf '{{"attrs":{{"name":["files"],"displayname":["Files"],"landing":["https://files.example.test"]}},"redirect_urls":["%s"]}}' "${{redirects[0]}}"
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
            serde_json::to_string(&dir.path().display().to_string()).expect("json path"),
        ),
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", &script).args([
        "--server-url",
        "https://id.example.test",
        "--admin-name",
        "admindsaw",
        "client",
        "redirect",
        "add",
        "files",
        "https://files.example.test/oauth2/callback",
    ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Warnings:"))
        .stdout(predicate::str::contains("add_redirect_url"));
}

#[test]
fn client_pkce_disable_downgrades_backend_failure_when_state_converged() {
    let dir = tempfile::tempdir().expect("tempdir");
    let script = dir.path().join("kanidm-stub.sh");
    write_script(
        &script,
        r#"#!/usr/bin/env bash
set -euo pipefail
args=("$@")
if [[ "${args[0]}" == "system" && "${args[1]}" == "oauth2" && "${args[2]}" == "warning-insecure-client-disable-pkce" ]]; then
  printf 'pkce already disabled\n' >&2
  exit 1
fi
if [[ "${args[0]}" == "system" && "${args[1]}" == "oauth2" && "${args[2]}" == "get" ]]; then
  printf '{"attrs":{"name":["files"],"displayname":["Files"]},"disable_pkce":[true]}'
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", &script).args([
        "--server-url",
        "https://id.example.test",
        "--admin-name",
        "admindsaw",
        "client",
        "pkce",
        "disable",
        "files",
    ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Warnings:"))
        .stdout(predicate::str::contains("disable_pkce"));
}

#[test]
fn user_create_rejects_invalid_account_id_before_backend() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
echo "backend should not be called: $*" >&2
exit 99
"#,
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", dir.path().join("kanidm-stub.sh"))
        .args([
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "user",
            "create",
            "bad name",
            "--display-name",
            "Bad Name",
        ]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("invalid account id"));
}

#[test]
fn user_create_rejects_invalid_email_before_backend() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
echo "backend should not be called: $*" >&2
exit 99
"#,
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", dir.path().join("kanidm-stub.sh"))
        .args([
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "user",
            "create",
            "dsaw",
            "--display-name",
            "Dan",
            "--email",
            "bad-email",
        ]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("invalid email"));
}

#[test]
fn client_redirect_add_rejects_relative_url_before_backend() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
echo "backend should not be called: $*" >&2
exit 99
"#,
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", dir.path().join("kanidm-stub.sh"))
        .args([
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "client",
            "redirect",
            "add",
            "files",
            "/oauth2/callback",
        ]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("invalid redirect URL"));
}

#[test]
fn reset_token_rejects_out_of_range_ttl_before_backend() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
echo "backend should not be called: $*" >&2
exit 99
"#,
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", dir.path().join("kanidm-stub.sh"))
        .args([
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "user",
            "reset-token",
            "dsaw",
            "--ttl",
            "30",
        ]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("invalid reset token TTL '30'"));
}

#[test]
fn policy_auth_expiry_rejects_out_of_range_value_before_backend() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
echo "backend should not be called: $*" >&2
exit 99
"#,
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", dir.path().join("kanidm-stub.sh"))
        .args([
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "policy",
            "group",
            "auth-expiry",
            "set",
            "idm_all_persons",
            "0",
        ]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("invalid auth expiry '0'"));
}
