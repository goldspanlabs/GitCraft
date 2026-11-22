use std::{io, path::{Path, PathBuf}, process::Command};

#[derive(Debug)]
pub enum GitError { Io(io::Error), Failed { code: Option<i32>, stderr: String } }
impl From<io::Error> for GitError { fn from(e: io::Error) -> Self { Self::Io(e) } }
impl std::fmt::Display for GitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { match self { Self::Io(e) => e.fmt(f), Self::Failed { code, stderr } => write!(f, "git failed ({code:?}): {stderr}") } }
}
impl std::error::Error for GitError {}

#[derive(Clone, Debug)]
pub struct GitCli { pub executable: PathBuf, pub workdir: PathBuf }
impl GitCli {
    pub fn new(path: impl Into<PathBuf>) -> Self { Self { executable: "git".into(), workdir: path.into() } }
    pub fn in_current_dir() -> io::Result<Self> { Ok(Self::new(std::env::current_dir()?)) }
    pub fn run<I, S>(&self, args: I) -> Result<String, GitError>
    where I: IntoIterator<Item = S>, S: AsRef<std::ffi::OsStr> {
        let out = Command::new(&self.executable).args(args).current_dir(&self.workdir).output()?;
        if out.status.success() { Ok(String::from_utf8_lossy(&out.stdout).into_owned()) }
        else { Err(GitError::Failed { code: out.status.code(), stderr: String::from_utf8_lossy(&out.stderr).trim().into() }) }
    }
    pub fn current_branch(&self) -> Result<String, GitError> { Ok(self.run(["branch", "--show-current"])?.trim().into()) }
    pub fn diff(&self, args: &[&str]) -> Result<String, GitError> { let mut a = vec!["diff"]; a.extend_from_slice(args); self.run(a) }
    pub fn log_oneline(&self, limit: usize) -> Result<Vec<String>, GitError> {
        Ok(self.run(["log", "--oneline", &format!("-{limit}")])?.lines().map(str::to_owned).collect())
    }
    pub fn repository_root(&self) -> Result<PathBuf, GitError> { Ok(self.run(["rev-parse", "--show-toplevel"])?.trim().into()) }
    pub fn workdir(&self) -> &Path { &self.workdir }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn constructs_with_workdir() { assert_eq!(GitCli::new("/repo").workdir(), Path::new("/repo")); }
}
