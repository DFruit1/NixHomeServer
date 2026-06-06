use std::{env, fs, os::unix::fs::PermissionsExt, path::Path, process::Command as ProcessCommand};

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

fn backend_should_not_run_dir() -> TempDir {
    stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
echo "backend should not be called: $*" >&2
exit 99
"#,
    )
}

fn command_with_stub(dir: &TempDir) -> Command {
    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", dir.path().join("kanidm-stub.sh"))
        .args([
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
        ]);
    cmd
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
fn session_status_ignores_other_users_sessions() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "session" && "$2" == "list" ]]; then
  cat <<'EOF'
---
spn: someone@example.test
uuid: 00000000-0000-0000-0000-000000000001
display: Someone
expiry: 2030-01-01T00:00:00Z
purpose: read write (expiry: 2030-01-01T00:30:00Z)
EOF
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
            "session",
            "status",
        ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains(
            "No active admin session was found for 'admindsaw'",
        ))
        .stdout(predicate::str::contains("kanidm-admin session login"));
}

#[test]
fn session_status_checks_admin_session_expiry() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "session" && "$2" == "list" ]]; then
  cat <<'EOF'
---
spn: admindsaw@example.test
uuid: 00000000-0000-0000-0000-000000000001
display: Dan
expiry: 2000-01-01T00:00:00Z
purpose: read write (expiry: 2030-01-01T00:30:00Z)
EOF
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
            "session",
            "status",
        ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains(
            "The previous admin session for 'admindsaw' has expired",
        ))
        .stdout(predicate::str::contains("kanidm-admin session login"));
}

#[test]
fn session_status_reports_reauth_required_when_base_session_is_active() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "session" && "$2" == "list" ]]; then
  cat <<'EOF'
---
spn: admindsaw@example.test
uuid: 00000000-0000-0000-0000-000000000001
display: Dan
expiry: 2030-01-01T00:00:00Z
purpose: read only
EOF
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
            "session",
            "status",
        ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains(
            "Privileged write access for 'admindsaw' requires reauthentication",
        ))
        .stdout(predicate::str::contains("kanidm-admin session reauth"));
}

#[test]
fn membership_set_rejects_empty_without_allow_empty() {
    let dir = backend_should_not_run_dir();

    let mut cmd = command_with_stub(&dir);
    cmd.args(["membership", "set", "dsaw"]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("requires --allow-empty"));
}

#[test]
fn membership_set_empty_requires_exact_confirmation() {
    let dir = backend_should_not_run_dir();

    let mut cmd = command_with_stub(&dir);
    cmd.args(["membership", "set", "dsaw", "--allow-empty"]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("requires --confirm-empty dsaw"));
}

#[test]
fn dry_run_membership_set_empty_reports_confirmation_without_backend() {
    let dir = backend_should_not_run_dir();

    let mut cmd = command_with_stub(&dir);
    cmd.args([
        "--dry-run",
        "--output",
        "json",
        "membership",
        "set",
        "dsaw",
        "--allow-empty",
    ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("\"dry_run\": true"))
        .stdout(predicate::str::contains("--confirm-empty dsaw"));
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
fn membership_add_to_sftp_group_triggers_local_sync_services() {
    let dir = tempfile::tempdir().expect("tempdir");
    let state_file = dir.path().join("groups.txt");
    let services_file = dir.path().join("services.txt");
    let chroot_base = dir.path().join("chroots");
    let users_root = dir.path().join("users");
    fs::write(&state_file, "").expect("seed groups");
    fs::write(&services_file, "").expect("seed services");
    fs::write(dir.path().join("vars.nix"), "{}").expect("vars");
    fs::create_dir_all(chroot_base.join("dsaw")).expect("chroot");
    fs::create_dir_all(users_root.join("dsaw")).expect("user root");
    let script = dir.path().join("kanidm");
    let nix = dir.path().join("nix");
    let nix_defaults = serde_json::to_string(&serde_json::json!({
        "serverUrl": "https://id.example.test",
        "adminName": "admindsaw",
        "vaultwardenUrl": "https://passwords.example.test",
        "sftpRuntime": {
            "sftpAccessGroup": "files-sftp-users",
            "localSftpAccessGroup": "files-local-sftp-users",
            "sftpChrootBase": chroot_base.display().to_string(),
            "usersRoot": users_root.display().to_string(),
            "filesSftpPort": 2222,
            "filesSftpSshdService": "files-sftp-sshd.service",
            "kanidmUnixdService": "kanidm-unixd.service",
            "posixGroupsService": "kanidm-files-posix-groups.service",
            "userRootSyncService": "fileshare-user-root-sync.service",
        }
    }))
    .expect("json defaults");
    write_script(
        &nix,
        &format!(
            r#"#!/usr/bin/env bash
set -euo pipefail
printf '%s' {}
"#,
            serde_json::to_string(&nix_defaults).expect("shell json")
        ),
    );
    write_script(
        &script,
        &format!(
            r#"#!/usr/bin/env bash
set -euo pipefail
state_file={}
args=("$@")
if [[ "${{args[0]}}" == "group" && "${{args[1]}}" == "add-members" && "${{args[2]}}" == "files-sftp-users" && "${{args[3]}}" == "dsaw" ]]; then
  printf 'files-sftp-users\n' > "$state_file"
  exit 0
fi
if [[ "${{args[0]}}" == "person" && "${{args[1]}}" == "get" && "${{args[2]}}" == "dsaw" ]]; then
  if grep -qx 'files-sftp-users' "$state_file"; then
    printf '{{"attrs":{{"name":["dsaw"],"displayname":["Dan"],"directmemberof":["files-sftp-users@example.test"]}}}}'
  else
    printf '{{"attrs":{{"name":["dsaw"],"displayname":["Dan"],"directmemberof":[]}}}}'
  fi
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
            serde_json::to_string(&state_file.display().to_string()).expect("json path"),
        ),
    );
    write_script(
        &dir.path().join("kanidm-unix"),
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "status" ]]; then
  printf 'system: online\nKanidm: online\n'
  exit 0
fi
exit 1
"#,
    );
    write_script(
        &dir.path().join("sudo"),
        &format!(
            r#"#!/usr/bin/env bash
set -euo pipefail
services_file={}
if [[ "$1" == "-n" && "$2" == "kanidm-admin-root" && "$3" == "systemd-start" ]]; then
  printf '%s\n' "$4" >> "$services_file"
  exit 0
fi
exit 1
"#,
            serde_json::to_string(&services_file.display().to_string()).expect("json path"),
        ),
    );
    write_script(
        &dir.path().join("systemctl"),
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "is-active" ]]; then
  printf 'active\n'
  exit 0
fi
exit 1
"#,
    );
    write_script(
        &dir.path().join("ss"),
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "-ltn" ]]; then
  printf 'State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
  printf 'LISTEN 0      128    0.0.0.0:2222       0.0.0.0:*\n'
  exit 0
fi
exit 1
"#,
    );
    write_script(
        &dir.path().join("getent"),
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "passwd" && "$2" == "dsaw" ]]; then
  printf 'dsaw:x:2000:2000:Dan:/home/dsaw:/bin/bash\n'
  exit 0
fi
exit 2
"#,
    );
    write_script(
        &dir.path().join("id"),
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "-nG" && "$2" == "dsaw" ]]; then
  printf 'users files-sftp-users\n'
  exit 0
fi
exit 1
"#,
    );
    write_script(
        &dir.path().join("findmnt"),
        r#"#!/usr/bin/env bash
set -euo pipefail
exit 0
"#,
    );
    let mut path_entries = vec![dir.path().to_path_buf()];
    if let Some(path) = env::var_os("PATH") {
        path_entries.extend(env::split_paths(&path));
    }
    let test_path = env::join_paths(path_entries).expect("join PATH");

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", &script)
        .env("KANIDM_ADMIN_REPO_ROOT", dir.path())
        .env("KANIDM_ADMIN_NIX_BIN", &nix)
        .env("PATH", test_path)
        .args([
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "--output",
            "json",
            "membership",
            "add",
            "dsaw",
            "files-sftp-users",
        ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("\"sftp_reconcile\""));
    let services = fs::read_to_string(services_file).expect("services");
    assert!(services.contains("kanidm-files-posix-groups.service"));
    assert!(services.contains("fileshare-user-root-sync.service"));
}

#[test]
fn membership_set_applies_diff_without_group_preflight_reads() {
    let dir = tempfile::tempdir().expect("tempdir");
    fs::write(dir.path().join("state.txt"), "before\n").expect("seed state");
    let script = dir.path().join("kanidm-stub.sh");
    write_script(
        &script,
        &format!(
            r#"#!/usr/bin/env bash
set -euo pipefail
state_file={}/state.txt
args=("$@")
if [[ "${{args[0]}}" == "group" && "${{args[1]}}" == "get" ]]; then
  echo "unexpected group preflight read: $*" >&2
  exit 44
fi
if [[ "${{args[0]}}" == "group" && "${{args[1]}}" == "add-members" ]]; then
  echo "unexpected add for remove-only diff: $*" >&2
  exit 45
fi
if [[ "${{args[0]}}" == "group" && "${{args[1]}}" == "remove-members" && "${{args[2]}}" == "domain_admins" && "${{args[3]}}" == "dsaw" ]]; then
  printf 'after\n' > "$state_file"
  exit 0
fi
if [[ "${{args[0]}}" == "person" && "${{args[1]}}" == "get" && "${{args[2]}}" == "dsaw" ]]; then
  state="$(<"$state_file")"
  if [[ "$state" == "before" ]]; then
    printf '{{"attrs":{{"name":["dsaw"],"displayname":["Dan"],"directmemberof":["app-admin@example.test","domain_admins@example.test","idm_all_accounts@example.test","idm_all_persons@example.test","users@example.test"]}}}}'
  else
    printf '{{"attrs":{{"name":["dsaw"],"displayname":["Dan"],"directmemberof":["app-admin@example.test","idm_all_accounts@example.test","idm_all_persons@example.test","users@example.test"]}}}}'
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
        "set",
        "dsaw",
        "app-admin",
        "idm_all_accounts",
        "idm_all_persons",
        "users",
    ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Removed:"))
        .stdout(predicate::str::contains("- domain_admins"));
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
        "--confirm-insecure-pkce-disable",
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
fn user_disable_downgrades_backend_failure_when_state_converged() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
args=("$@")
if [[ "${args[0]}" == "person" && "${args[1]}" == "validity" && "${args[2]}" == "expire-at" ]]; then
  printf 'user already disabled\n' >&2
  exit 1
fi
if [[ "${args[0]}" == "person" && "${args[1]}" == "get" && "${args[2]}" == "dsaw" ]]; then
  printf '{"attrs":{"name":["dsaw"],"displayname":["Dan"],"account_expire":["2000-01-01T00:00:00Z"]}}'
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
            "disable",
            "dsaw",
        ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Disabled Kanidm user 'dsaw'"))
        .stdout(predicate::str::contains("Warnings:"))
        .stdout(predicate::str::contains("person_disable"));
}

#[test]
fn user_enable_returns_partial_success_when_second_step_fails_without_convergence() {
    let dir = tempfile::tempdir().expect("tempdir");
    let state = dir.path().join("expiry-cleared");
    let script = dir.path().join("kanidm-stub.sh");
    write_script(
        &script,
        &format!(
            r#"#!/usr/bin/env bash
set -euo pipefail
state_file={}
args=("$@")
if [[ "${{args[0]}}" == "person" && "${{args[1]}}" == "validity" && "${{args[2]}}" == "expire-at" && "${{args[4]}}" == "clear" ]]; then
  : > "$state_file"
  exit 0
fi
if [[ "${{args[0]}}" == "person" && "${{args[1]}}" == "validity" && "${{args[2]}}" == "begin-from" && "${{args[4]}}" == "clear" ]]; then
  printf 'begin-from clear failed\n' >&2
  exit 1
fi
if [[ "${{args[0]}}" == "person" && "${{args[1]}}" == "get" && "${{args[2]}}" == "dsaw" && -f "$state_file" ]]; then
  printf '{{"attrs":{{"name":["dsaw"],"displayname":["Dan"],"account_valid_from":["2030-01-01T00:00:00Z"]}}}}'
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
"#,
            serde_json::to_string(&state.display().to_string()).expect("json path"),
        ),
    );

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", &script).args([
        "--server-url",
        "https://id.example.test",
        "--admin-name",
        "admindsaw",
        "user",
        "enable",
        "dsaw",
    ]);

    cmd.assert()
        .code(8)
        .stderr(predicate::str::contains("was modified"))
        .stderr(predicate::str::contains("clear_expiry"))
        .stderr(predicate::str::contains("clear_valid_from"));
}

#[test]
fn policy_auth_expiry_downgrades_backend_failure_when_state_converged() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
args=("$@")
if [[ "${args[0]}" == "group" && "${args[1]}" == "account-policy" && "${args[2]}" == "auth-expiry" ]]; then
  printf 'policy already set\n' >&2
  exit 1
fi
if [[ "${args[0]}" == "group" && "${args[1]}" == "get" && "${args[2]}" == "idm_all_persons" ]]; then
  printf '{"attrs":{"name":["idm_all_persons"],"auth_expiry":["7200"]}}'
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
            "policy",
            "group",
            "auth-expiry",
            "set",
            "idm_all_persons",
            "7200",
        ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Warnings:"))
        .stdout(predicate::str::contains("set_auth_expiry"))
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
        "No active admin session was found for 'admindsaw'. Run `kanidm-admin session login` to log in.",
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
        "Privileged write access for 'admindsaw' requires reauthentication. Run `kanidm-admin session reauth` first.",
    ));
}

#[test]
fn session_required_sanitizes_upstream_terminal_panic_noise() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
cat >&2 <<'EOF'
2026-05-07T11:43:44.977001Z ERROR kanidm_cli::common: Session has expired for admindsaw@example.test - you may need to login again.

thread 'main' (15995) panicked at /build/source/tools/cli/src/cli/common.rs:312:26:
Failed to interact with interactive session: Io(Custom { kind: NotConnected, error: "not a terminal" })
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
EOF
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

    cmd.assert()
        .code(6)
        .stderr(predicate::str::contains(
            "The previous admin session for 'admindsaw' has expired. Run `kanidm-admin session login` to log in again.",
        ))
        .stderr(predicate::str::contains("thread 'main'").not())
        .stderr(predicate::str::contains("not a terminal").not());
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
        "--confirm-insecure-pkce-disable",
        "files",
    ]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Warnings:"))
        .stdout(predicate::str::contains("disable_pkce"));
}

#[test]
fn user_create_rejects_invalid_account_id_before_backend() {
    let dir = backend_should_not_run_dir();

    let mut cmd = command_with_stub(&dir);
    cmd.args(["user", "create", "bad name", "--display-name", "Bad Name"]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("invalid account id"));
}

#[test]
fn user_create_rejects_invalid_email_before_backend() {
    let dir = backend_should_not_run_dir();

    let mut cmd = command_with_stub(&dir);
    cmd.args([
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
    let dir = backend_should_not_run_dir();

    let mut cmd = command_with_stub(&dir);
    cmd.args(["client", "redirect", "add", "files", "/oauth2/callback"]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("invalid redirect URL"));
}

#[test]
fn client_redirect_add_rejects_cross_site_public_url_before_backend() {
    let dir = backend_should_not_run_dir();

    let mut cmd = command_with_stub(&dir);
    cmd.args([
        "client",
        "redirect",
        "add",
        "files",
        "https://evil.example.org/oauth2/callback",
    ]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("public redirect host must be"));
}

#[test]
fn client_secret_reset_requires_exact_confirmation_before_backend() {
    let dir = backend_should_not_run_dir();

    let mut cmd = command_with_stub(&dir);
    cmd.args(["client", "secret", "reset", "files"]);

    cmd.assert().code(2).stderr(predicate::str::contains(
        "requires --confirm-rotate-secret files",
    ));
}

#[test]
fn client_pkce_disable_requires_exact_confirmation_before_backend() {
    let dir = backend_should_not_run_dir();

    let mut cmd = command_with_stub(&dir);
    cmd.args(["client", "pkce", "disable", "files"]);

    cmd.assert().code(2).stderr(predicate::str::contains(
        "requires --confirm-insecure-pkce-disable files",
    ));
}

#[test]
fn client_consent_disable_requires_exact_confirmation_before_backend() {
    let dir = backend_should_not_run_dir();

    let mut cmd = command_with_stub(&dir);
    cmd.args(["client", "consent", "disable", "files"]);

    cmd.assert().code(2).stderr(predicate::str::contains(
        "requires --confirm-disable-consent files",
    ));
}

#[test]
fn reset_token_rejects_out_of_range_ttl_before_backend() {
    let dir = backend_should_not_run_dir();

    let mut cmd = command_with_stub(&dir);
    cmd.args(["user", "reset-token", "dsaw", "--ttl", "30"]);

    cmd.assert()
        .code(2)
        .stderr(predicate::str::contains("invalid reset token TTL '30'"));
}

#[test]
fn policy_auth_expiry_rejects_out_of_range_value_before_backend() {
    let dir = backend_should_not_run_dir();

    let mut cmd = command_with_stub(&dir);
    cmd.args([
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

#[test]
fn history_list_runs_without_kanidm_or_nix_context() {
    let dir = tempfile::tempdir().expect("tempdir");
    let history_dir = dir.path().join("history");

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env_clear()
        .env("HOME", dir.path())
        .env("KANIDM_ADMIN_HISTORY_DIR", &history_dir)
        .args(["history", "list"]);

    cmd.assert().success().stdout(predicate::str::contains(
        "No kanidm-admin operation history",
    ));
}

#[test]
fn context_show_uses_installed_context_when_repo_root_is_absent() {
    let dir = tempfile::tempdir().expect("tempdir");
    let context_file = dir.path().join("context.json");
    fs::write(
        &context_file,
        r#"{
  "serverUrl": "https://id.example.test",
  "adminName": "admindsaw",
  "vaultwardenUrl": "https://passwords.example.test",
  "sftpRuntime": {
    "sftpAccessGroup": "installed-sftp-users",
    "localSftpAccessGroup": "installed-local-sftp-users"
  }
}"#,
    )
    .expect("context file");

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env_clear()
        .env("HOME", dir.path())
        .env("KANIDM_ADMIN_CONTEXT_FILE", &context_file)
        .env(
            "KANIDM_ADMIN_REPO_ROOT",
            dir.path().join("missing-source-repo"),
        )
        .args(["context", "show"]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("https://id.example.test"))
        .stdout(predicate::str::contains("installed-sftp-users"));
}

#[test]
fn history_redact_sensitive_runs_without_kanidm_or_nix_context() {
    let dir = tempfile::tempdir().expect("tempdir");
    let history_dir = dir.path().join("history");
    fs::create_dir_all(&history_dir).expect("history dir");
    fs::write(
        history_dir.join("operations.jsonl"),
        r#"{"args":["kanidm-admin","client","secret","show","files"],"details":{"raw_output":"SECRET"}}"#,
    )
    .expect("history");

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env_clear()
        .env("HOME", dir.path())
        .env("KANIDM_ADMIN_HISTORY_DIR", &history_dir)
        .args(["history", "redact-sensitive"]);

    cmd.assert()
        .success()
        .stdout(predicate::str::contains("Redacted sensitive fields"));
    let persisted = fs::read_to_string(history_dir.join("operations.jsonl")).expect("history");
    assert!(!persisted.contains("SECRET"));
}

#[test]
fn jellyfin_password_stage_runs_without_kanidm_or_nix_context() {
    let dir = tempfile::tempdir().expect("tempdir");
    let hash_dir = dir.path().join("hashes");

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env_clear()
        .env("HOME", dir.path())
        .env("JELLYFIN_PASSWORD", "correct horse battery staple")
        .env("KANIDM_ADMIN_JELLYFIN_PASSWORD_HASH_DIR", &hash_dir)
        .args(["local", "jellyfin-password", "stage", "alice"]);

    cmd.assert().success().stdout(predicate::str::contains(
        "Staged the desired Jellyfin password hash",
    ));
    assert!(hash_dir.join("alice.pbkdf2").is_file());
}

#[test]
fn sensitive_backend_failure_redacts_error_and_history() {
    let dir = stub_dir(
        r#"#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "person" && "$2" == "credential" && "$3" == "create-reset-token" ]]; then
  printf 'SECRET_RESET_STDOUT\n'
  printf 'SECRET_RESET_STDERR\n' >&2
  exit 42
fi
echo "unexpected args: $*" >&2
exit 1
"#,
    );
    let history_root = tempfile::tempdir().expect("history root");
    let history_dir = history_root.path().join("history");

    let mut cmd = Command::cargo_bin("kanidm-admin").expect("binary");
    cmd.env("KANIDM_ADMIN_KANIDM_BIN", dir.path().join("kanidm-stub.sh"))
        .env("KANIDM_ADMIN_HISTORY_DIR", &history_dir)
        .args([
            "--server-url",
            "https://id.example.test",
            "--admin-name",
            "admindsaw",
            "--json",
            "user",
            "reset-token",
            "alice",
        ]);

    cmd.assert()
        .code(10)
        .stderr(predicate::str::contains("SECRET_RESET").not())
        .stderr(predicate::str::contains("<redacted>"));
    let persisted = fs::read_to_string(history_dir.join("operations.jsonl")).expect("history");
    assert!(!persisted.contains("SECRET_RESET"));
    assert!(persisted.contains("<redacted>"));
}

#[test]
fn local_helper_help_describes_subcommands() {
    let mut vaultwarden = Command::cargo_bin("kanidm-admin").expect("binary");
    vaultwarden.args(["local", "vaultwarden", "--help"]);
    vaultwarden
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "Create or refresh a pending Vaultwarden invite",
        ))
        .stdout(predicate::str::contains(
            "Inspect Vaultwarden invite/account state",
        ));

    let mut jellyfin = Command::cargo_bin("kanidm-admin").expect("binary");
    jellyfin.args(["local", "jellyfin-password", "--help"]);
    jellyfin
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "Write a staged Jellyfin password hash",
        ))
        .stdout(predicate::str::contains(
            "Start the Jellyfin password reconciler",
        ));
}
