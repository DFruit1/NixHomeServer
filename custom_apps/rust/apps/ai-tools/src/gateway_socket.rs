//! Consume exactly the Unix stream listener supplied by systemd. The service
//! never creates a writable socket pathname or changes Caddy's socket ownership.

use std::{
    env, io,
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::net::UnixListener,
    },
    path::Path,
};

fn activation_contract(
    path: Option<&str>,
    pid: Option<&str>,
    fds: Option<&str>,
) -> io::Result<Option<String>> {
    match (path, pid, fds) {
        (None, None, None) => Ok(None),
        (Some(path), Some(pid), Some("1"))
            if path.starts_with("/run/") && pid.parse::<u32>().ok() == Some(std::process::id()) =>
        {
            Ok(Some(path.to_owned()))
        }
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid gateway socket activation",
        )),
    }
}

pub(super) fn inherited() -> io::Result<Option<tokio::net::UnixListener>> {
    let path = optional_env("AI_TOOLS_GATEWAY_SOCKET")?;
    let pid = optional_env("LISTEN_PID")?;
    let fds = optional_env("LISTEN_FDS")?;
    let Some(path) = activation_contract(path.as_deref(), pid.as_deref(), fds.as_deref())? else {
        return Ok(None);
    };
    // Check that fd 3 exists before constructing its owning Rust value.
    if unsafe { libc::fcntl(3, libc::F_GETFD) } < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the checked activation contract transfers ownership of exactly
    // descriptor 3 to this process. This function runs once, before any binds.
    let fd = unsafe { OwnedFd::from_raw_fd(3) };
    listener_from_fd(fd, Path::new(&path)).map(Some)
}

fn optional_env(name: &str) -> io::Result<Option<String>> {
    match env::var(name) {
        Ok(value) => Ok(Some(value)),
        Err(env::VarError::NotPresent) => Ok(None),
        Err(_) => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid socket activation environment",
        )),
    }
}

fn listener_from_fd(fd: OwnedFd, expected_path: &Path) -> io::Result<tokio::net::UnixListener> {
    // sd_listen_fds normally sets FD_CLOEXEC. Do so ourselves before a helper
    // can be spawned: it must never inherit the trusted gateway listener.
    // SAFETY: both fcntl calls operate on a live owned descriptor only.
    let flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFD) };
    if flags < 0
        || unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0
    {
        return Err(io::Error::last_os_error());
    }
    for (option, expected) in [(libc::SO_TYPE, libc::SOCK_STREAM), (libc::SO_ACCEPTCONN, 1)] {
        let mut actual: libc::c_int = 0;
        let mut length = std::mem::size_of_val(&actual) as libc::socklen_t;
        // SAFETY: getsockopt receives valid pointers to the integer and its size.
        if unsafe {
            libc::getsockopt(
                fd.as_raw_fd(),
                libc::SOL_SOCKET,
                option,
                (&mut actual as *mut libc::c_int).cast(),
                &mut length,
            )
        } < 0
        {
            return Err(io::Error::last_os_error());
        }
        if actual != expected {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "gateway socket must be a listening stream",
            ));
        }
    }
    let listener = UnixListener::from(fd);
    if listener.local_addr()?.as_pathname() != Some(expected_path) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unexpected gateway socket pathname",
        ));
    }
    listener.set_nonblocking(true)?;
    tokio::net::UnixListener::from_std(listener)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn activation_rejects_missing_or_foreign_descriptors() {
        let pid = std::process::id().to_string();
        let path = "/run/ai-tools-gateway.sock";
        assert_eq!(activation_contract(None, None, None).unwrap(), None);
        assert_eq!(
            activation_contract(Some(path), Some(&pid), Some("1")).unwrap(),
            Some(path.to_owned())
        );
        for (path, pid, fds) in [
            (Some(path), None, None),
            (None, Some(pid.as_str()), Some("1")),
            (Some(path), Some("0"), Some("1")),
            (Some(path), Some(pid.as_str()), Some("0")),
            (Some(path), Some(pid.as_str()), Some("2")),
            (Some("relative.sock"), Some(pid.as_str()), Some("1")),
        ] {
            assert!(activation_contract(path, pid, fds).is_err());
        }
    }

    #[tokio::test]
    async fn only_the_expected_listener_is_accepted_and_not_inherited() {
        let dir = crate::tests::SyntheticSharedRoot::new("activation");
        let path = dir.join("gateway.sock");
        let fd: OwnedFd = UnixListener::bind(&path).unwrap().into();
        let listener = listener_from_fd(fd, &path).unwrap();
        let flags = unsafe { libc::fcntl(listener.as_raw_fd(), libc::F_GETFD) };
        assert_ne!(flags & libc::FD_CLOEXEC, 0);
        let fd: OwnedFd = UnixListener::bind(dir.join("other.sock")).unwrap().into();
        assert!(listener_from_fd(fd, &path).is_err());
        let fd: OwnedFd = std::fs::File::open("/dev/null").unwrap().into();
        assert!(listener_from_fd(fd, &path).is_err());
        let fd: OwnedFd = std::os::unix::net::UnixDatagram::unbound().unwrap().into();
        assert!(listener_from_fd(fd, &path).is_err());
    }
}
