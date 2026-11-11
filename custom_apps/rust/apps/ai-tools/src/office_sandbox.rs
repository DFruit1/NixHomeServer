//! A fresh exec boundary keeps Landlock/allocator setup out of pre_exec in the
//! multi-threaded server. The parser gets only stdin/stdout/stderr and Nix-store
//! code; denied syscalls also close io_uring and cross-process escape routes.

use landlock::{
    path_beneath_rules, Access, AccessFs, Ruleset, RulesetAttr, RulesetCreatedAttr, RulesetStatus,
    ABI,
};
use std::{io, os::unix::process::CommandExt, process::Command};

pub(crate) fn install() -> Result<(), String> {
    let abi = ABI::V3;
    let status = Ruleset::default()
        .handle_access(AccessFs::from_all(abi))
        .map_err(|_| "Parser filesystem sandbox is unavailable")?
        .create()
        .map_err(|_| "Parser filesystem sandbox is unavailable")?
        .add_rules(path_beneath_rules(
            ["/nix/store"],
            AccessFs::from_read(abi) | AccessFs::Execute,
        ))
        .map_err(|_| "Parser filesystem sandbox is unavailable")?
        .restrict_self()
        .map_err(|_| "Parser filesystem sandbox is unavailable")?;
    if status.ruleset != RulesetStatus::FullyEnforced {
        return Err("Parser filesystem sandbox is not fully enforced".into());
    }
    network_and_process_filter().map_err(|_| "Parser syscall sandbox is unavailable")?;
    for (resource, soft, hard) in [
        (libc::RLIMIT_AS, 768 * 1024 * 1024, 768 * 1024 * 1024),
        (libc::RLIMIT_CPU, 30, 30),
        (libc::RLIMIT_CORE, 0, 0),
        (libc::RLIMIT_FSIZE, 0, 0),
    ] {
        let limit = libc::rlimit {
            rlim_cur: soft,
            rlim_max: hard,
        };
        if unsafe { libc::setrlimit(resource, &limit) } != 0 {
            return Err("Parser resource limits are unavailable".into());
        }
    }
    Ok(())
}

#[cfg(target_arch = "x86_64")]
fn network_and_process_filter() -> io::Result<()> {
    const LOAD: u16 = 0x20;
    const EQ: u16 = 0x15;
    const GE: u16 = 0x35;
    const RET: u16 = 0x06;
    const KILL: u32 = 0x80000000;
    let ins = |code, jt, jf, k| libc::sock_filter { code, jt, jf, k };
    let mut filter = vec![
        ins(LOAD, 0, 0, 4),
        ins(EQ, 1, 0, 0xc000003e),
        ins(RET, 0, 0, KILL),
        ins(LOAD, 0, 0, 0),
        ins(GE, 0, 1, 0x40000000),
        ins(RET, 0, 0, KILL),
    ];
    // prlimit64(pid, ...) can alter another same-UID process's limits; allow it
    // only for the parser itself (pid 0) so startup resource tuning remains possible.
    filter.extend([
        ins(EQ, 0, 6, libc::SYS_prlimit64 as u32),
        ins(LOAD, 0, 0, 16),
        ins(EQ, 0, 2, 0),
        ins(LOAD, 0, 0, 20),
        ins(EQ, 1, 0, 0),
        ins(RET, 0, 0, 0x00050000 | libc::EPERM as u32),
        ins(RET, 0, 0, 0x7fff0000),
    ]);
    for syscall in [
        libc::SYS_socket,
        libc::SYS_socketpair,
        libc::SYS_connect,
        libc::SYS_accept,
        libc::SYS_accept4,
        libc::SYS_io_uring_setup,
        libc::SYS_io_uring_enter,
        libc::SYS_io_uring_register,
        libc::SYS_ptrace,
        libc::SYS_process_vm_readv,
        libc::SYS_process_vm_writev,
        libc::SYS_pidfd_getfd,
        libc::SYS_pidfd_send_signal,
        libc::SYS_perf_event_open,
        libc::SYS_bpf,
        libc::SYS_kill,
        libc::SYS_tkill,
        libc::SYS_tgkill,
        libc::SYS_rt_sigqueueinfo,
        libc::SYS_rt_tgsigqueueinfo,
        libc::SYS_fork,
        libc::SYS_vfork,
        libc::SYS_clone,
        libc::SYS_clone3,
    ] {
        filter.extend([
            ins(EQ, 0, 1, syscall as u32),
            ins(RET, 0, 0, 0x00050000 | libc::EPERM as u32),
        ]);
    }
    filter.push(ins(RET, 0, 0, 0x7fff0000));
    let program = libc::sock_fprog {
        len: filter.len() as u16,
        filter: filter.as_mut_ptr(),
    };
    // SAFETY: the BPF program remains live until prctl copies it. Unknown
    // architectures/x32 ABIs are killed rather than bypassing the syscall list.
    if unsafe { libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) } != 0
        || unsafe { libc::prctl(libc::PR_SET_SECCOMP, libc::SECCOMP_MODE_FILTER, &program) } != 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(not(target_arch = "x86_64"))]
fn network_and_process_filter() -> io::Result<()> {
    Err(io::Error::from(io::ErrorKind::Unsupported))
}

pub(crate) fn run() -> ! {
    let result = (|| -> Result<(), String> {
        let helper =
            std::env::var("AI_TOOLS_PARSER_HELPER").map_err(|_| "Parser is not configured")?;
        if !helper.starts_with("/nix/store/") {
            return Err("Parser must come from the pinned Nix package".into());
        }
        install()?;
        // No activation listener, broker connection, document FD or server
        // reactor descriptor may survive into the parser.
        if unsafe { libc::syscall(libc::SYS_close_range, 3u32, u32::MAX, 0u32) } != 0 {
            return Err("Parser descriptor isolation is unavailable".into());
        }
        let _error = Command::new(helper)
            .env_clear()
            .env("PYTHONDONTWRITEBYTECODE", "1")
            .exec();
        Err("Parser could not start".into())
    })();
    if let Err(error) = result {
        eprintln!("{error}");
    }
    // A failed exec must not unwind through a runtime whose FDs were closed.
    std::process::exit(1)
}

#[cfg(test)]
mod tests {
    #[test]
    fn office_parser_sandbox_blocks_files_sockets_and_io_uring() {
        const CHILD: &str = "AI_TOOLS_SANDBOX_TEST_CHILD";
        if std::env::var_os(CHILD).is_some() {
            super::install().expect("fully enforced parser sandbox");
            assert!(std::fs::read("/etc/passwd").is_err());
            assert!(std::fs::read_dir("/nix/store").is_ok());
            assert_eq!(
                unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) },
                -1
            );
            assert_eq!(
                unsafe { libc::socket(libc::AF_INET, libc::SOCK_STREAM, 0) },
                -1
            );
            assert_eq!(
                unsafe {
                    libc::syscall(
                        libc::SYS_io_uring_setup,
                        0,
                        std::ptr::null_mut::<libc::c_void>(),
                    )
                },
                -1
            );
            assert_eq!(
                std::io::Error::last_os_error().raw_os_error(),
                Some(libc::EPERM)
            );
            // Signal 0 probes permission without harming the separate same-UID
            // parent if a filter regression occurs. Every alternative signal
            // entry point must hit seccomp, not kernel argument validation.
            let parent = unsafe { libc::getppid() };
            for syscall in [
                libc::SYS_tkill,
                libc::SYS_tgkill,
                libc::SYS_rt_sigqueueinfo,
                libc::SYS_rt_tgsigqueueinfo,
            ] {
                let result = unsafe {
                    match syscall {
                        libc::SYS_tkill => libc::syscall(syscall, parent, 0),
                        libc::SYS_tgkill => libc::syscall(syscall, parent, parent, 0),
                        libc::SYS_rt_sigqueueinfo => {
                            libc::syscall(syscall, parent, 0, std::ptr::null::<libc::siginfo_t>())
                        }
                        _ => libc::syscall(
                            syscall,
                            parent,
                            parent,
                            0,
                            std::ptr::null::<libc::siginfo_t>(),
                        ),
                    }
                };
                assert_eq!(result, -1);
                assert_eq!(
                    std::io::Error::last_os_error().raw_os_error(),
                    Some(libc::EPERM)
                );
            }
            let denied = libc::rlimit64 {
                rlim_cur: 0,
                rlim_max: 0,
            };
            assert_eq!(
                unsafe {
                    libc::prlimit64(parent, libc::RLIMIT_NOFILE, &denied, std::ptr::null_mut())
                },
                -1
            );
            assert_eq!(
                std::io::Error::last_os_error().raw_os_error(),
                Some(libc::EPERM)
            );
            let mut current = libc::rlimit64 {
                rlim_cur: 0,
                rlim_max: 0,
            };
            assert_eq!(
                unsafe { libc::prlimit64(0, libc::RLIMIT_NOFILE, std::ptr::null(), &mut current) },
                0
            );
            return;
        }
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "office_sandbox::tests::office_parser_sandbox_blocks_files_sockets_and_io_uring",
                "--nocapture",
            ])
            .env(CHILD, "1")
            .status()
            .unwrap();
        assert!(
            status.success(),
            "parser sandbox failed its isolated Linux checks"
        );
    }
}
