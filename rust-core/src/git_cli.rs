use std::{
    ffi::OsString,
    io::{self, Read},
    path::Path,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

/// Read-only queries (status, log, diff, ...) should finish quickly.
const READ_TIMEOUT: Duration = Duration::from_secs(60);
/// Mutations include network transfers and hooks, so they get much longer.
const MUTATE_TIMEOUT: Duration = Duration::from_secs(10 * 60);
/// Availability probes (`git --version`) should never hang the UI.
const PROBE_TIMEOUT: Duration = Duration::from_secs(5);

/// Output of a completed git command, preserving its exit status for callers
/// (such as `git merge-tree`) where non-zero exit codes carry structured meaning.
pub struct CommandOutput {
    pub status: std::process::ExitStatus,
    pub stdout: String,
    pub stderr: String,
}

/// Runs a read-only git command and returns its exit status, stdout, and stderr.
pub fn run_status(repo: &Path, args: &[&str]) -> Result<CommandOutput, crate::GitCraftError> {
    execute_raw(repo, args, READ_TIMEOUT, false)
}

/// Runs a read-only git command and returns its stdout.
///
/// Sets `GIT_OPTIONAL_LOCKS=0` so queries like `git status` never rewrite the index,
/// which would otherwise make our own file watcher see a change and refresh again.
pub fn run(repo: &Path, args: &[&str]) -> Result<String, crate::GitCraftError> {
    execute(repo, args, READ_TIMEOUT, false)
}

/// Runs a git command that changes the repository (or talks to a remote).
pub fn mutate(repo: &Path, args: &[&str]) -> Result<(), crate::GitCraftError> {
    execute(repo, args, MUTATE_TIMEOUT, true).map(|_| ())
}

fn execute_raw(
    repo: &Path,
    args: &[&str],
    timeout: Duration,
    mutating: bool,
) -> Result<CommandOutput, crate::GitCraftError> {
    let mut command = Command::new("git");
    command
        // Report non-ASCII paths verbatim instead of as "\303\251" escapes.
        .args(["-c", "core.quotepath=off"])
        // Abort HTTP transfers that stall instead of hanging the app.
        .args([
            "-c",
            "http.lowSpeedLimit=1000",
            "-c",
            "http.lowSpeedTime=30",
        ])
        .args(args)
        .current_dir(repo)
        .env("PATH", augmented_path())
        // There is no terminal to prompt on: fail with an error instead of waiting.
        .env("GIT_TERMINAL_PROMPT", "0")
        // The app matches some of git's messages (for example "divergent branches"), so keep
        // them in English whatever the system language is.
        .env("LC_MESSAGES", "C")
        .env_remove("LANGUAGE");
    // An inherited LC_ALL would override LC_MESSAGES. Drop it, keeping its value as the
    // character-type locale so hooks still see the encoding they had.
    if let Some(all) = std::env::var_os("LC_ALL") {
        command.env_remove("LC_ALL");
        if std::env::var_os("LC_CTYPE").is_none() {
            command.env("LC_CTYPE", all);
        }
    }
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if !mutating {
        command.env("GIT_OPTIONAL_LOCKS", "0");
    }
    let child = command.spawn().map_err(|err| {
        if err.kind() == io::ErrorKind::NotFound && repo.exists() {
            crate::GitCraftError::GitNotFound
        } else {
            crate::GitCraftError::from(err)
        }
    })?;
    let captured = wait_with_timeout(child, timeout, args.first().copied().unwrap_or("git"))?;
    Ok(CommandOutput {
        status: captured.status,
        stdout: String::from_utf8_lossy(&captured.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&captured.stderr).into_owned(),
    })
}

fn execute(
    repo: &Path,
    args: &[&str],
    timeout: Duration,
    mutating: bool,
) -> Result<String, crate::GitCraftError> {
    let output = execute_raw(repo, args, timeout, mutating)?;
    if output.status.success() {
        Ok(output.stdout)
    } else {
        let stderr = output.stderr.trim();
        let stdout = output.stdout.trim();
        // Some failures (e.g. "nothing to commit") are reported on stdout, and a killed
        // process says nothing at all; never return an empty message.
        let message = if !stderr.is_empty() {
            stderr.to_owned()
        } else if !stdout.is_empty() {
            stdout.to_owned()
        } else {
            format!(
                "git {} failed ({})",
                args.first().copied().unwrap_or(""),
                output.status
            )
        };
        Err(crate::GitCraftError::message(message))
    }
}

struct Captured {
    status: std::process::ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

fn wait_with_timeout(mut child: Child, timeout: Duration, name: &str) -> io::Result<Captured> {
    // Drain both pipes on their own threads so a chatty child can't block on a full pipe.
    let drain = |mut pipe: Box<dyn Read + Send>| {
        thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = pipe.read_to_end(&mut buf);
            buf
        })
    };
    let stdout = child.stdout.take().map(|p| drain(Box::new(p)));
    let stderr = child.stderr.take().map(|p| drain(Box::new(p)));

    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!(
                    "git {name} timed out after {} seconds and was stopped",
                    timeout.as_secs()
                ),
            ));
        }
        thread::sleep(Duration::from_millis(15));
    };

    let collect = |handle: Option<thread::JoinHandle<Vec<u8>>>| {
        handle.and_then(|h| h.join().ok()).unwrap_or_default()
    };
    Ok(Captured {
        status,
        stdout: collect(stdout),
        stderr: collect(stderr),
    })
}

/// Checks whether the `git` CLI is installed and runnable using the augmented PATH.
pub fn check_availability() -> crate::GitAvailability {
    check_availability_in_path(&augmented_path(), PROBE_TIMEOUT)
}

fn check_availability_in_path(
    path_env: &std::ffi::OsStr,
    timeout: Duration,
) -> crate::GitAvailability {
    let child = match Command::new("git")
        .arg("--version")
        .env("PATH", path_env)
        .env("LC_MESSAGES", "C")
        .env_remove("LANGUAGE")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(_) => return crate::GitAvailability::Missing,
    };

    match wait_with_timeout(child, timeout, "--version") {
        Ok(captured) if captured.status.success() => crate::GitAvailability::Available,
        Ok(captured) => {
            let stderr = String::from_utf8_lossy(&captured.stderr).to_ascii_lowercase();
            if stderr.contains("xcode-select") || stderr.contains("developer tools") {
                crate::GitAvailability::NeedsCommandLineTools
            } else {
                crate::GitAvailability::Missing
            }
        }
        Err(_) => crate::GitAvailability::Missing,
    }
}

/// A GUI app launched from Finder gets a minimal PATH, so tools used by hooks and
/// credential helpers (Homebrew, /usr/local) would be missing. Append the usual
/// locations after whatever is already there.
fn augmented_path() -> OsString {
    let mut parts: Vec<std::path::PathBuf> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect())
        .unwrap_or_default();
    for extra in ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"] {
        let extra = std::path::PathBuf::from(extra);
        if !parts.contains(&extra) {
            parts.push(extra);
        }
    }
    std::env::join_paths(parts).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_repo() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        run(dir.path(), &["init", "-q"]).unwrap();
        dir
    }

    #[test]
    fn slow_command_is_stopped_at_the_timeout() {
        let dir = temp_repo();
        let started = Instant::now();
        let child = Command::new("git")
            .args(["-c", "alias.slow=!sleep 30", "slow"])
            .current_dir(dir.path())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let err = match wait_with_timeout(child, Duration::from_millis(300), "slow") {
            Ok(_) => panic!("expected a timeout"),
            Err(e) => e,
        };
        assert_eq!(err.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(10));
    }

    #[test]
    fn large_output_does_not_deadlock() {
        let dir = temp_repo();
        let out = run(
            dir.path(),
            &["-c", "alias.big=!yes | head -c 2000000", "big"],
        )
        .unwrap();
        assert_eq!(out.len(), 2_000_000);
    }

    #[test]
    fn failure_returns_stderr_text() {
        let dir = temp_repo();
        let err = run(dir.path(), &["rev-parse", "nope-not-a-ref"]).unwrap_err();
        assert!(!err.to_string().is_empty());
    }

    #[test]
    fn credential_prompts_fail_instead_of_waiting() {
        // With no terminal, git must error out rather than block on a prompt.
        let dir = temp_repo();
        let started = Instant::now();
        let result = run(
            dir.path(),
            &["ls-remote", "https://127.0.0.1:1/nonexistent.git"],
        );
        assert!(result.is_err());
        assert!(started.elapsed() < Duration::from_secs(20));
    }

    #[test]
    fn git_messages_are_not_translated() {
        let dir = temp_repo();
        let out = run(dir.path(), &["-c", "alias.msg=!echo $LC_MESSAGES", "msg"]).unwrap();
        assert_eq!(out.trim(), "C");
    }

    #[test]
    fn path_includes_homebrew_locations() {
        let path = augmented_path();
        let text = path.to_string_lossy();
        assert!(text.contains("/opt/homebrew/bin"));
        assert!(text.contains("/usr/local/bin"));
    }

    #[test]
    fn availability_detects_present_missing_and_clt_stub() {
        use std::os::unix::fs::PermissionsExt;

        assert_eq!(check_availability(), crate::GitAvailability::Available);

        let empty_dir = tempfile::tempdir().unwrap();
        assert_eq!(
            check_availability_in_path(empty_dir.path().as_os_str(), PROBE_TIMEOUT),
            crate::GitAvailability::Missing
        );

        let stub_dir = tempfile::tempdir().unwrap();
        let fake_git = stub_dir.path().join("git");
        std::fs::write(
            &fake_git,
            "#!/bin/sh\necho 'xcode-select: note: No developer tools were found' >&2\nexit 1\n",
        )
        .unwrap();
        let mut perms = std::fs::metadata(&fake_git).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&fake_git, perms).unwrap();

        assert_eq!(
            check_availability_in_path(stub_dir.path().as_os_str(), PROBE_TIMEOUT),
            crate::GitAvailability::NeedsCommandLineTools
        );

        let slow_dir = tempfile::tempdir().unwrap();
        let slow_git = slow_dir.path().join("git");
        std::fs::write(&slow_git, "#!/bin/sh\nsleep 30\n").unwrap();
        let mut slow_perms = std::fs::metadata(&slow_git).unwrap().permissions();
        slow_perms.set_mode(0o755);
        std::fs::set_permissions(&slow_git, slow_perms).unwrap();

        let started = Instant::now();
        assert_eq!(
            check_availability_in_path(slow_dir.path().as_os_str(), Duration::from_millis(200)),
            crate::GitAvailability::Missing
        );
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn missing_repo_directory_preserves_io_error_instead_of_git_not_found() {
        let missing_dir = tempfile::tempdir().unwrap();
        let missing_path = missing_dir.path().join("does-not-exist");
        let err = run(&missing_path, &["status"]).unwrap_err();
        assert!(matches!(err, crate::GitCraftError::Message { .. }));

        let io_err = io::Error::new(io::ErrorKind::NotFound, "missing file");
        assert!(matches!(
            crate::GitCraftError::from(io_err),
            crate::GitCraftError::Message { .. }
        ));
    }
}
