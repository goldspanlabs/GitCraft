use std::{io, path::Path, process::Command};

pub fn run(repo: &Path, args: &[&str]) -> io::Result<String> {
    let output = Command::new("git").args(args).current_dir(repo).output()?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    } else {
        Err(io::Error::other(
            String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        ))
    }
}

pub fn mutate(repo: &Path, args: &[&str]) -> io::Result<()> {
    run(repo, args).map(|_| ())
}
