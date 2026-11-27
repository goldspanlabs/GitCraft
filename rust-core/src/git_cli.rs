use std::{
    ffi::{CString, OsStr, OsString},
    io::{self, Read},
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
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
    execute_raw(repo, args, READ_TIMEOUT, false, None)
}

/// Like [`run_status`], with `input` written to the command's standard input.
pub fn run_status_with_input(
    repo: &Path,
    args: &[&str],
    input: Vec<u8>,
) -> Result<CommandOutput, crate::GitCraftError> {
    execute_raw(repo, args, READ_TIMEOUT, false, Some(input))
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

/// Like [`mutate`], returning what the command printed, for commands whose output says what
/// they did (such as `push --porcelain`).
pub fn mutate_output(repo: &Path, args: &[&str]) -> Result<String, crate::GitCraftError> {
    execute(repo, args, MUTATE_TIMEOUT, true)
}

fn execute_raw(
    repo: &Path,
    args: &[&str],
    timeout: Duration,
    mutating: bool,
    input: Option<Vec<u8>>,
) -> Result<CommandOutput, crate::GitCraftError> {
    let path_env = augmented_path();
    let Some(git) = resolve_git(&path_env) else {
        // A missing repository folder is the more useful thing to report.
        std::fs::metadata(repo)?;
        return Err(crate::GitCraftError::GitNotFound);
    };
    let mut command = git_command(git, &path_env);
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
        // There is no terminal to prompt on: fail with an error instead of waiting.
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if !mutating {
        command.env("GIT_OPTIONAL_LOCKS", "0");
    }
    let mut child = command.spawn().map_err(|err| {
        if err.kind() == io::ErrorKind::NotFound && repo.exists() {
            crate::GitCraftError::GitNotFound
        } else {
            crate::GitCraftError::from(err)
        }
    })?;
    if let (Some(input), Some(mut stdin)) = (input, child.stdin.take()) {
        // Written from another thread: git may fill its output pipe before it has read all of it.
        thread::spawn(move || {
            let _ = io::Write::write_all(&mut stdin, &input);
        });
    }
    let captured = wait_with_timeout(
        child,
        timeout,
        args.first().copied().unwrap_or("git"),
        mutating,
    )?;
    Ok(CommandOutput {
        status: captured.status,
        stdout: String::from_utf8_lossy(&captured.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&captured.stderr).into_owned(),
    })
}

/// A command that runs `git` with `path_env` as its `PATH` and its messages in English.
fn git_command(git: PathBuf, path_env: &OsStr) -> Command {
    let mut command = Command::new(git);
    command
        .env("PATH", path_env)
        // The app matches some of git's messages (for example "divergent branches" or
        // "xcode-select"), so keep them in English whatever the system language is.
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
}

fn execute(
    repo: &Path,
    args: &[&str],
    timeout: Duration,
    mutating: bool,
) -> Result<String, crate::GitCraftError> {
    let output = execute_raw(repo, args, timeout, mutating, None)?;
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

/// How long to sleep before asking again whether a command has finished: an eighth of the time
/// it has run, so quick commands are not held back and long ones don't keep waking the app.
fn poll_delay(elapsed: Duration) -> Duration {
    (elapsed / 8).clamp(Duration::from_micros(500), Duration::from_millis(15))
}

fn wait_with_timeout(
    mut child: Child,
    timeout: Duration,
    name: &str,
    allow_incomplete_output: bool,
) -> io::Result<Captured> {
    use std::sync::mpsc;

    // Drain both pipes on their own threads so a chatty child can't block on a full pipe.
    let drain = |mut pipe: Box<dyn Read + Send>| {
        let (tx, rx) = mpsc::sync_channel(1);
        thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = pipe.read_to_end(&mut buf);
            let _ = tx.send(buf);
        });
        rx
    };
    let stdout_rx = child.stdout.take().map(|p| drain(Box::new(p)));
    let stderr_rx = child.stderr.take().map(|p| drain(Box::new(p)));

    let started = Instant::now();
    let deadline = started + timeout;
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
        thread::sleep(poll_delay(started.elapsed()));
    };

    let collect = |rx: Option<mpsc::Receiver<Vec<u8>>>| -> Result<Vec<u8>, ()> {
        let Some(rx) = rx else {
            return Ok(Vec::new());
        };
        let remaining = deadline.saturating_duration_since(Instant::now());
        match rx.recv_timeout(remaining) {
            Ok(buf) => Ok(buf),
            Err(mpsc::RecvTimeoutError::Disconnected) => Ok(Vec::new()),
            Err(mpsc::RecvTimeoutError::Timeout) => Err(()),
        }
    };

    let stdout = collect(stdout_rx);
    let stderr = collect(stderr_rx);
    match (stdout, stderr) {
        (Ok(stdout), Ok(stderr)) => Ok(Captured {
            status,
            stdout,
            stderr,
        }),
        (stdout, stderr) if allow_incomplete_output => Ok(Captured {
            status,
            stdout: stdout.unwrap_or_default(),
            stderr: stderr.unwrap_or_default(),
        }),
        _ => Err(io::Error::new(
            io::ErrorKind::TimedOut,
            format!(
                "git {name} exited ({status}), but a background process kept output open after {} seconds",
                timeout.as_secs()
            ),
        )),
    }
}

/// The oldest git the app is tested with, as major and minor version. CI runs the Rust tests
/// against it, and the README states it.
const MINIMUM_VERSION: (u32, u32) = (2, 39);

/// [`MINIMUM_VERSION`] as shown to the user.
pub fn minimum_version() -> String {
    format!("{}.{}", MINIMUM_VERSION.0, MINIMUM_VERSION.1)
}

/// Major and minor version from `git version 2.39.5 (Apple Git-154)`.
fn parse_version(output: &str) -> Option<(u32, u32)> {
    let mut parts = output.trim().strip_prefix("git version ")?.split('.');
    Some((parts.next()?.parse().ok()?, parts.next()?.parse().ok()?))
}

/// Checks whether the `git` CLI is installed, runnable and recent enough, using the augmented
/// PATH.
pub fn check_availability() -> crate::GitAvailability {
    check_availability_in_path(&augmented_path(), PROBE_TIMEOUT)
}

fn check_availability_in_path(path_env: &OsStr, timeout: Duration) -> crate::GitAvailability {
    let Some(git) = resolve_git(path_env) else {
        return crate::GitAvailability::Missing;
    };
    let child = match git_command(git, path_env)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(_) => return crate::GitAvailability::Missing,
    };

    match wait_with_timeout(child, timeout, "--version", false) {
        Ok(captured) if captured.status.success() => {
            match parse_version(&String::from_utf8_lossy(&captured.stdout)) {
                Some(version) if version < MINIMUM_VERSION => crate::GitAvailability::Outdated,
                _ => crate::GitAvailability::Available,
            }
        }
        Ok(captured) => {
            let stderr = String::from_utf8_lossy(&captured.stderr).to_ascii_lowercase();
            if stderr.contains("xcode-select") || stderr.contains("developer tools") {
                crate::GitAvailability::NeedsCommandLineTools
            } else {
                crate::GitAvailability::Missing
            }
        }
        // Git is there but slow, as on the first run after a boot. Calling it missing would
        // drop the repository being opened; real commands have their own timeouts.
        Err(e) if e.kind() == io::ErrorKind::TimedOut => crate::GitAvailability::Available,
        Err(_) => crate::GitAvailability::Missing,
    }
}

/// The first `git` this process may execute in an absolute directory of `path_env`.
///
/// Passing a full path matters on macOS: given a bare name and a custom `PATH`, `Command`
/// uses `fork` instead of `posix_spawn`, and a forked child of a multithreaded process can
/// crash in a system library before it reaches `exec`. That shows up as git dying with
/// SIGKILL.
fn resolve_git(path_env: &OsStr) -> Option<PathBuf> {
    std::env::split_paths(path_env)
        .filter(|dir| dir.is_absolute())
        .map(|dir| dir.join("git"))
        .find(|candidate| candidate.is_file() && is_executable(candidate))
}

/// Asks the system whether the effective user may execute `path`. The mode bits alone
/// don't say: they depend on who owns the file, and access control lists can override them.
fn is_executable(path: &Path) -> bool {
    let Ok(path) = CString::new(path.as_os_str().as_bytes()) else {
        return false;
    };
    // SAFETY: `path` is a NUL-terminated string that outlives the call.
    unsafe { libc::faccessat(libc::AT_FDCWD, path.as_ptr(), libc::X_OK, libc::AT_EACCESS) == 0 }
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
    fn quick_commands_are_checked_often_and_slow_ones_rarely() {
        let ms = Duration::from_millis;
        assert_eq!(poll_delay(Duration::ZERO), Duration::from_micros(500));
        assert_eq!(poll_delay(ms(40)), ms(5));
        assert_eq!(poll_delay(ms(10_000)), ms(15));
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
        let err = match wait_with_timeout(child, Duration::from_millis(300), "slow", false) {
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
    fn git_commands_are_spawned_without_forking() {
        use std::{cell::Cell, ffi::c_int, sync::Once};

        extern "C" {
            fn pthread_atfork(
                prepare: Option<extern "C" fn()>,
                parent: Option<extern "C" fn()>,
                child: Option<extern "C" fn()>,
            ) -> c_int;
        }
        // The prepare handler runs on the forking thread, so a thread-local count ignores
        // forks made by tests running in parallel.
        thread_local!(static FORKS: Cell<u32> = const { Cell::new(0) });
        extern "C" fn count_fork() {
            FORKS.with(|forks| forks.set(forks.get() + 1));
        }
        static REGISTER: Once = Once::new();
        REGISTER.call_once(|| {
            assert_eq!(unsafe { pthread_atfork(Some(count_fork), None, None) }, 0);
        });

        let dir = temp_repo();
        run(dir.path(), &["status"]).unwrap();
        mutate(dir.path(), &["add", "-A"]).unwrap();
        assert_eq!(check_availability(), crate::GitAvailability::Available);

        assert_eq!(FORKS.with(Cell::get), 0);
    }

    /// Writes a `git` shell script with `body` to `dir`, with permission bits `mode`.
    fn fake_git_script(dir: &Path, body: &str, mode: u32) {
        use std::os::unix::fs::PermissionsExt;

        let path = dir.join("git");
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
    }

    /// A `git` that does nothing and succeeds.
    fn fake_git(dir: &Path, mode: u32) {
        fake_git_script(dir, "exit 0", mode);
    }

    /// A temporary folder holding an executable `git` script with `body`.
    fn folder_with_git(body: &str) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        fake_git_script(dir.path(), body, 0o755);
        dir
    }

    #[test]
    fn git_lookup_skips_a_file_this_user_cannot_execute() {
        let blocked = tempfile::tempdir().unwrap();
        let usable = tempfile::tempdir().unwrap();
        // Executable by the group and others, but not by the owner running the test.
        fake_git(blocked.path(), 0o655);
        fake_git(usable.path(), 0o755);
        let path = std::env::join_paths([blocked.path(), usable.path()]).unwrap();

        assert_eq!(
            check_availability_in_path(&path, PROBE_TIMEOUT),
            crate::GitAvailability::Available
        );
    }

    #[test]
    fn git_in_a_relative_path_entry_is_not_run() {
        let dir = tempfile::tempdir().unwrap();
        fake_git(dir.path(), 0o755);
        // The same folder, spelled relative to the current directory.
        let depth = std::env::current_dir().unwrap().components().count() - 1;
        let relative =
            PathBuf::from("../".repeat(depth)).join(dir.path().strip_prefix("/").unwrap());
        assert!(relative.join("git").exists());

        assert_eq!(
            check_availability_in_path(relative.as_os_str(), PROBE_TIMEOUT),
            crate::GitAvailability::Missing
        );
    }

    #[test]
    fn path_includes_homebrew_locations() {
        let path = augmented_path();
        let text = path.to_string_lossy();
        assert!(text.contains("/opt/homebrew/bin"));
        assert!(text.contains("/usr/local/bin"));
    }

    /// How a `git` that prints `output` for `--version` is judged.
    fn availability_of(output: &str) -> crate::GitAvailability {
        let dir = folder_with_git(&format!("echo '{output}'"));
        check_availability_in_path(dir.path().as_os_str(), PROBE_TIMEOUT)
    }

    #[test]
    fn git_older_than_the_minimum_is_reported_as_outdated() {
        use crate::GitAvailability::{Available, Outdated};

        for old in [
            "git version 2.38.1",
            "git version 2.32.0 (Apple Git-132)",
            "git version 1.9.5",
        ] {
            assert_eq!(availability_of(old), Outdated, "{old}");
        }
        for new in [
            "git version 2.39.0",
            "git version 2.39.5 (Apple Git-154)",
            "git version 2.100.0",
            "git version 3.0.0-rc1",
        ] {
            assert_eq!(availability_of(new), Available, "{new}");
        }
        // Not being able to read the version is no reason to lock the user out.
        assert_eq!(availability_of("something else"), Available);
    }

    #[test]
    fn availability_detects_present_missing_and_clt_stub() {
        assert_eq!(check_availability(), crate::GitAvailability::Available);

        let empty_dir = tempfile::tempdir().unwrap();
        assert_eq!(
            check_availability_in_path(empty_dir.path().as_os_str(), PROBE_TIMEOUT),
            crate::GitAvailability::Missing
        );

        let stub_dir =
            folder_with_git("echo 'xcode-select: note: No developer tools were found' >&2\nexit 1");

        assert_eq!(
            check_availability_in_path(stub_dir.path().as_os_str(), PROBE_TIMEOUT),
            crate::GitAvailability::NeedsCommandLineTools
        );

        let sleep_bin = if Path::new("/bin/sleep").exists() {
            "/bin/sleep"
        } else {
            "/usr/bin/sleep"
        };
        let slow_dir = folder_with_git(&format!("exec {sleep_bin} 30"));

        let started = Instant::now();
        assert_eq!(
            check_availability_in_path(slow_dir.path().as_os_str(), Duration::from_millis(200)),
            // The first run on a cold machine can be slow; that doesn't mean git is absent.
            crate::GitAvailability::Available
        );
        let elapsed = started.elapsed();
        assert!(elapsed >= Duration::from_millis(180));
        assert!(elapsed < Duration::from_secs(5));
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
