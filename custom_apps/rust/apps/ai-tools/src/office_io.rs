//! The only filesystem operations exposed by the Office broker. These run in
//! a fresh worker AFTER every credential and capability has been verified.
//! No document parser runs in this process, and replacements are unsupported.

use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    ffi::CString,
    fs::File,
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{ffi::OsStrExt, fs::MetadataExt},
    },
    path::Path,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::UnixStream,
};
use uuid::Uuid;

pub(crate) const MAX_DOCUMENT: usize = 32 * 1024 * 1024;
pub(crate) const MAX_FRAME: usize = 48 * 1024 * 1024;

#[derive(Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum Operation {
    Read { path: String },
    Create { name: String, document: String },
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Request {
    pub subject: String,
    pub username: String,
    pub operation: Operation,
}

pub(crate) async fn receive(stream: &mut UnixStream) -> Result<Vec<u8>, String> {
    let size = stream
        .read_u32()
        .await
        .map_err(|_| "Office file access is unavailable")? as usize;
    if size == 0 || size > MAX_FRAME {
        return Err("Office request exceeds its size limit".into());
    }
    let mut data = vec![0; size];
    stream
        .read_exact(&mut data)
        .await
        .map_err(|_| "Office file access is unavailable")?;
    Ok(data)
}

pub(crate) async fn send(stream: &mut UnixStream, bytes: &[u8]) -> Result<(), String> {
    if bytes.is_empty() || bytes.len() > MAX_FRAME {
        return Err("Office response exceeds its size limit".into());
    }
    stream
        .write_u32(bytes.len() as u32)
        .await
        .map_err(|_| "Office file access is unavailable")?;
    stream
        .write_all(bytes)
        .await
        .map_err(|_| "Office file access is unavailable")?;
    Ok(())
}

pub(crate) async fn call(
    socket: &Path,
    actor: &crate::gateway::AuthenticatedCaller,
    operation: Operation,
) -> Result<Value, String> {
    let request = serde_json::to_vec(&Request {
        subject: actor.subject().into(),
        username: actor.username().into(),
        operation,
    })
    .map_err(|_| "Invalid Office request")?;
    tokio::time::timeout(std::time::Duration::from_secs(90), async {
        let mut stream = UnixStream::connect(socket)
            .await
            .map_err(|_| "Office file access is unavailable")?;
        send(&mut stream, &request).await?;
        let response: Value = serde_json::from_slice(&receive(&mut stream).await?)
            .map_err(|_| "Invalid Office response")?;
        if let Some(error) = response.get("error").and_then(Value::as_str) {
            return Err(error.to_owned());
        }
        response
            .get("result")
            .cloned()
            .ok_or_else(|| "Invalid Office response".into())
    })
    .await
    .map_err(|_| {
        "Office file access timed out; inspect the workspace before retrying a save".to_string()
    })?
}

pub(crate) fn safe_relative(value: &str) -> Result<&str, String> {
    if value.is_empty()
        || value.len() > 2048
        || value.contains('\0')
        || value.contains('\\')
        || value.split('/').any(|p| p.is_empty() || p.starts_with('.'))
    {
        return Err("Use a relative non-hidden document name".into());
    }
    Ok(value)
}

#[repr(C)]
struct OpenHow {
    flags: u64,
    mode: u64,
    resolve: u64,
}

fn open_at(
    dir: libc::c_int,
    name: &std::ffi::CStr,
    flags: libc::c_int,
    mode: u32,
    beneath: bool,
) -> std::io::Result<File> {
    let how = OpenHow {
        flags: (flags | libc::O_CLOEXEC) as u64,
        mode: mode as u64,
        resolve: 0x02 | 0x04 | if beneath { 0x08 } else { 0 },
    };
    // SAFETY: openat2 receives a live NUL-terminated name and correctly-sized
    // OpenHow; successful ownership of the returned descriptor transfers once.
    let fd = unsafe {
        libc::syscall(
            libc::SYS_openat2,
            dir,
            name.as_ptr(),
            &how,
            std::mem::size_of::<OpenHow>(),
        )
    };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_fd(fd as libc::c_int) })
}

fn root(path: &Path) -> std::io::Result<File> {
    let name = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    open_at(
        libc::AT_FDCWD,
        &name,
        libc::O_PATH | libc::O_DIRECTORY,
        0,
        false,
    )
}

pub(crate) fn perform(
    operation: Operation,
    shared: &Path,
    workspace: &Path,
) -> Result<Value, String> {
    let denied = |_| "Document access denied or unavailable".to_string();
    match operation {
        Operation::Read { path } => {
            let path = CString::new(safe_relative(&path)?).map_err(|_| "Invalid document name")?;
            let root = root(shared).map_err(denied)?;
            let file = open_at(
                root.as_raw_fd(),
                &path,
                libc::O_RDONLY | libc::O_NONBLOCK,
                0,
                true,
            )
            .map_err(denied)?;
            let metadata = file.metadata().map_err(denied)?;
            if !metadata.is_file() || metadata.nlink() != 1 || metadata.len() > MAX_DOCUMENT as u64
            {
                return Err("Document is not an eligible regular file or exceeds 32 MiB".into());
            }
            let mut data = Vec::new();
            let mut bounded = file.take(MAX_DOCUMENT as u64 + 1);
            bounded.read_to_end(&mut data).map_err(denied)?;
            let after = bounded.get_ref().metadata().map_err(denied)?;
            if data.len() > MAX_DOCUMENT
                || after.nlink() != 1
                || after.len() != metadata.len()
                || after.mtime() != metadata.mtime()
                || after.mtime_nsec() != metadata.mtime_nsec()
                || after.ctime() != metadata.ctime()
                || after.ctime_nsec() != metadata.ctime_nsec()
            {
                return Err("Document changed while reading; try again".into());
            }
            Ok(json!({"document":base64::engine::general_purpose::STANDARD.encode(data)}))
        }
        Operation::Create { name, document } => {
            safe_relative(&name)?;
            // The root-owned workspace is directly beneath the sticky shared
            // root. Single-component targets keep publication in that pinned,
            // non-renamable directory rather than a caller-movable subtree.
            if name.contains('/') {
                return Err("Output name must not contain directories".into());
            }
            if document.len() > (MAX_DOCUMENT.div_ceil(3) * 4) {
                return Err("Output exceeds 32 MiB".into());
            }
            let data = base64::engine::general_purpose::STANDARD
                .decode(document)
                .map_err(|_| "Invalid document output")?;
            if data.len() > MAX_DOCUMENT {
                return Err("Output exceeds 32 MiB".into());
            }
            if workspace.parent() != Some(shared) {
                return Err("Workspace must be directly below the shared root".into());
            }
            let parent = root(shared).map_err(denied)?;
            let parent_metadata = parent.metadata().map_err(denied)?;
            if parent_metadata.uid() != 0 || parent_metadata.mode() & libc::S_ISVTX == 0 {
                return Err("Shared root must be root-owned and sticky".into());
            }
            let component =
                CString::new(workspace.file_name().ok_or("Invalid workspace")?.as_bytes())
                    .map_err(|_| "Invalid workspace")?;
            let directory = open_at(
                parent.as_raw_fd(),
                &component,
                libc::O_PATH | libc::O_DIRECTORY,
                0,
                true,
            )
            .map_err(denied)?;
            if directory.metadata().map_err(denied)?.uid() != 0 {
                return Err("Workspace ownership is not safe for publication".into());
            }
            let stage = CString::new(format!(".ai-tools-{}.part", Uuid::new_v4()))
                .map_err(|_| "Invalid staging name")?;
            let target = CString::new(name.as_str()).map_err(|_| "Invalid output name")?;
            let mut file = open_at(
                directory.as_raw_fd(),
                &stage,
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
                0o600,
                true,
            )
            .map_err(denied)?;
            // Failed stages are intentionally retained rather than unlinking a
            // pathname another writer might have replaced in this shared dir.
            file.write_all(&data)
                .and_then(|_| file.sync_all())
                .map_err(denied)?;
            let written = file.metadata().map_err(denied)?;
            if written.nlink() != 1 {
                return Err("Output changed while saving".into());
            }
            let staged = open_at(directory.as_raw_fd(), &stage, libc::O_PATH, 0, true)
                .map_err(denied)?
                .metadata()
                .map_err(denied)?;
            if (staged.dev(), staged.ino()) != (written.dev(), written.ino()) {
                return Err("Output changed while saving".into());
            }
            // Atomic publication must never replace an existing destination.
            let rc = unsafe {
                libc::syscall(
                    libc::SYS_renameat2,
                    directory.as_raw_fd(),
                    stage.as_ptr(),
                    directory.as_raw_fd(),
                    target.as_ptr(),
                    libc::RENAME_NOREPLACE,
                )
            };
            if rc < 0 {
                return Err(
                    "Could not publish output; choose a new name and inspect the workspace".into(),
                );
            }
            let published = open_at(directory.as_raw_fd(), &target, libc::O_PATH, 0, true)
                .map_err(denied)?
                .metadata()
                .map_err(denied)?;
            if (published.dev(), published.ino(), published.nlink())
                != (written.dev(), written.ino(), 1)
            {
                return Err("Output changed while saving".into());
            }
            Ok(json!({"name":name,"bytes":data.len(),"created":true,"overwritten":false}))
        }
    }
}

#[repr(C)]
#[derive(Default, Copy, Clone, PartialEq, Eq)]
struct CapData {
    effective: u32,
    permitted: u32,
    inheritable: u32,
}
#[repr(C)]
struct CapHeader {
    version: u32,
    pid: i32,
}

/// Called only in Command::pre_exec: every operation here is a Linux syscall
/// using preallocated arguments. No allocator, locks, NSS or document opens.
pub(crate) unsafe fn drop_credentials(
    principal: &crate::office_identity::Principal,
) -> std::io::Result<()> {
    let check = |rc: libc::c_int| {
        if rc == 0 {
            Ok(())
        } else {
            Err(std::io::Error::last_os_error())
        }
    };
    unsafe {
        check(libc::setgroups(
            principal.groups.len(),
            principal.groups.as_ptr(),
        ))?;
        check(libc::setresgid(principal.gid, principal.gid, principal.gid))?;
        check(libc::setresuid(principal.uid, principal.uid, principal.uid))?;
        libc::setfsuid(principal.uid);
        libc::setfsgid(principal.gid);
        let header = CapHeader {
            version: 0x20080522,
            pid: 0,
        };
        let empty = [CapData::default(); 2];
        check(libc::syscall(libc::SYS_capset, &header, empty.as_ptr()) as libc::c_int)?;
        check(libc::prctl(
            libc::PR_CAP_AMBIENT,
            libc::PR_CAP_AMBIENT_CLEAR_ALL,
            0,
            0,
            0,
        ))?;
        check(libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0))?;
        let mut actual = [CapData::default(); 2];
        check(libc::syscall(libc::SYS_capget, &header, actual.as_mut_ptr()) as libc::c_int)?;
        let (mut ruid, mut euid, mut suid) = (0, 0, 0);
        let (mut rgid, mut egid, mut sgid) = (0, 0, 0);
        check(libc::getresuid(&mut ruid, &mut euid, &mut suid))?;
        check(libc::getresgid(&mut rgid, &mut egid, &mut sgid))?;
        let mut groups = [0; 129];
        let count = libc::getgroups(groups.len() as libc::c_int, groups.as_mut_ptr());
        if count < 0 {
            return Err(std::io::Error::last_os_error());
        }
        groups[..count as usize].sort_unstable();
        if actual != empty
            || (ruid, euid, suid) != (principal.uid, principal.uid, principal.uid)
            || (rgid, egid, sgid) != (principal.gid, principal.gid, principal.gid)
            || groups[..count as usize] != principal.groups[..]
        {
            return Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied));
        }
    }
    Ok(())
}

pub(crate) fn verify_worker() -> Result<(), String> {
    let uid: u32 = std::env::var("AI_TOOLS_WORKER_UID")
        .map_err(|_| "Unverified Office worker")?
        .parse()
        .map_err(|_| "Unverified Office worker")?;
    let gid: u32 = std::env::var("AI_TOOLS_WORKER_GID")
        .map_err(|_| "Unverified Office worker")?
        .parse()
        .map_err(|_| "Unverified Office worker")?;
    let expected: Vec<u32> = serde_json::from_str(
        &std::env::var("AI_TOOLS_WORKER_GROUPS").map_err(|_| "Unverified Office worker")?,
    )
    .map_err(|_| "Unverified Office worker")?;
    let header = CapHeader {
        version: 0x20080522,
        pid: 0,
    };
    let mut caps = [CapData::default(); 2];
    let mut groups = [0; 129];
    let count = unsafe { libc::getgroups(groups.len() as libc::c_int, groups.as_mut_ptr()) };
    if count < 0 || uid < 1000 || gid < 1000 {
        return Err("Unverified Office worker".into());
    }
    groups[..count as usize].sort_unstable();
    let (mut ruid, mut euid, mut suid, mut rgid, mut egid, mut sgid) = (0, 0, 0, 0, 0, 0);
    if unsafe { libc::getresuid(&mut ruid, &mut euid, &mut suid) } != 0
        || unsafe { libc::getresgid(&mut rgid, &mut egid, &mut sgid) } != 0
        || (ruid, euid, suid, rgid, egid, sgid) != (uid, uid, uid, gid, gid, gid)
        || unsafe { libc::setfsuid(u32::MAX) } as u32 != uid
        || unsafe { libc::setfsgid(u32::MAX) } as u32 != gid
        || unsafe { libc::syscall(libc::SYS_capget, &header, caps.as_mut_ptr()) } != 0
        || caps != [CapData::default(); 2]
        || unsafe { libc::getuid() } != uid
        || unsafe { libc::geteuid() } != uid
        || unsafe { libc::getgid() } != gid
        || unsafe { libc::getegid() } != gid
        || groups[..count as usize] != expected[..]
        || unsafe { libc::prctl(libc::PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) } != 1
    {
        return Err("Unverified Office worker".into());
    }
    for capability in 0..64 {
        if unsafe {
            libc::prctl(
                libc::PR_CAP_AMBIENT,
                libc::PR_CAP_AMBIENT_IS_SET,
                capability,
                0,
                0,
            )
        } > 0
        {
            return Err("Unverified Office worker".into());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    // Catastrophic-risk regression: an omitted capset could let a caller
    // regain broker credentials. Run explicitly in a mapped user namespace;
    // ordinary build sandboxes need not grant user-namespace creation.
    #[test]
    #[ignore = "run in unshare --user --map-auto --map-root-user --setgroups allow"]
    fn office_worker_drops_nonroot_capabilities_and_cannot_overwrite() {
        use std::os::unix::fs::PermissionsExt;
        const PHASE: &str = "AI_TOOLS_CREDENTIAL_TEST_ROOT";
        if let Some(root) = std::env::var_os(PHASE) {
            verify_worker().unwrap();
            let shared = Path::new(&root);
            let workspace = shared.join("workspace");
            assert!(perform(
                Operation::Read {
                    path: "private.xlsx".into()
                },
                shared,
                &workspace
            )
            .is_err());
            assert!(perform(
                Operation::Read {
                    path: "allowed.xlsx".into()
                },
                shared,
                &workspace
            )
            .is_ok());
            let document = base64::engine::general_purpose::STANDARD.encode(b"new copy");
            assert!(perform(
                Operation::Create {
                    name: "copy.xlsx".into(),
                    document: document.clone()
                },
                shared,
                &workspace
            )
            .is_ok());
            assert!(perform(
                Operation::Create {
                    name: "copy.xlsx".into(),
                    document
                },
                shared,
                &workspace
            )
            .is_err());
            assert_eq!(
                std::fs::read(workspace.join("copy.xlsx")).unwrap(),
                b"new copy"
            );
            assert_eq!(
                std::fs::metadata(workspace.join("copy.xlsx"))
                    .unwrap()
                    .uid(),
                2000
            );
            assert_eq!(unsafe { libc::setresuid(1500, 1500, 1500) }, -1);
            assert_eq!(unsafe { libc::setresuid(0, 0, 0) }, -1);
            return;
        }
        assert_eq!(
            unsafe { libc::getuid() },
            0,
            "run inside the documented mapped namespace"
        );
        let root =
            std::env::temp_dir().join(format!("office-credential-test-{}", std::process::id()));
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o1777)).unwrap();
        let workspace = root.join("workspace");
        std::fs::create_dir(&workspace).unwrap();
        std::fs::set_permissions(&workspace, std::fs::Permissions::from_mode(0o777)).unwrap();
        std::fs::write(root.join("private.xlsx"), b"private").unwrap();
        std::fs::set_permissions(
            root.join("private.xlsx"),
            std::fs::Permissions::from_mode(0o600),
        )
        .unwrap();
        std::fs::write(root.join("allowed.xlsx"), b"allowed").unwrap();
        std::fs::set_permissions(
            root.join("allowed.xlsx"),
            std::fs::Permissions::from_mode(0o644),
        )
        .unwrap();
        let executable = root.join("credential-test");
        std::fs::copy(std::env::current_exe().unwrap(), &executable).unwrap();
        let mut command = std::process::Command::new(executable);
        command
            .args([
                "--exact",
                "office_io::tests::office_worker_drops_nonroot_capabilities_and_cannot_overwrite",
                "--ignored",
                "--nocapture",
            ])
            .env(PHASE, &root)
            .env("AI_TOOLS_WORKER_UID", "2000")
            .env("AI_TOOLS_WORKER_GID", "2000")
            .env("AI_TOOLS_WORKER_GROUPS", "[2000,2001]");
        use std::os::unix::process::CommandExt;
        let principal = crate::office_identity::Principal {
            uid: 2000,
            gid: 2000,
            groups: vec![2000, 2001],
        };
        unsafe {
            command.pre_exec(move || {
                if libc::prctl(libc::PR_SET_KEEPCAPS, 1, 0, 0, 0) != 0
                    || libc::setresgid(1500, 1500, 1500) != 0
                    || libc::setresuid(1500, 1500, 1500) != 0
                {
                    return Err(std::io::Error::last_os_error());
                }
                let header = CapHeader {
                    version: 0x20080522,
                    pid: 0,
                };
                let bits = (1 << 7) | (1 << 6); // CAP_SETUID / CAP_SETGID
                let caps = [
                    CapData {
                        effective: bits,
                        permitted: bits,
                        inheritable: 0,
                    },
                    CapData::default(),
                ];
                if libc::syscall(libc::SYS_capset, &header, caps.as_ptr()) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                drop_credentials(&principal)
            });
        }
        let status = command.status().unwrap();
        std::fs::remove_dir_all(root).unwrap();
        assert!(status.success(), "credential child: {status}");
    }
    #[test]
    fn office_io_rejects_hidden_absolute_parent_and_empty_paths() {
        for path in [
            "",
            "/etc/passwd",
            "a/../b",
            "a//b",
            ".hidden",
            "a/.b",
            "a\\b",
        ] {
            assert!(safe_relative(path).is_err());
        }
        assert!(safe_relative("Reports/quote.docx").is_ok());
    }
    #[test]
    fn office_io_reads_only_regular_single_link_files_beneath_the_root() {
        let dir = crate::tests::SyntheticSharedRoot::new("office-io");
        let root = dir.join("root");
        std::fs::create_dir(&root).unwrap();
        std::fs::write(root.join("plain.docx"), b"synthetic").unwrap();
        assert!(perform(
            Operation::Read {
                path: "plain.docx".into()
            },
            &root,
            &root
        )
        .is_ok());
        std::os::unix::fs::symlink("/etc/passwd", root.join("link.docx")).unwrap();
        assert!(perform(
            Operation::Read {
                path: "link.docx".into()
            },
            &root,
            &root
        )
        .is_err());
        std::fs::hard_link(root.join("plain.docx"), root.join("copy.docx")).unwrap();
        assert!(perform(
            Operation::Read {
                path: "plain.docx".into()
            },
            &root,
            &root
        )
        .is_err());
        assert!(perform(
            Operation::Read {
                path: "../outside".into()
            },
            &root,
            &root
        )
        .is_err());
    }
}
