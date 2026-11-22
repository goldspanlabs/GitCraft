use std::{collections::BTreeMap, fs, io, path::{Path, PathBuf}, time::{Duration, SystemTime}};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ChangeKind { Created, Modified, Removed }
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Change { pub path: PathBuf, pub kind: ChangeKind }

#[derive(Clone, Debug)]
pub struct PollWatcher { root: PathBuf, snapshot: BTreeMap<PathBuf, SystemTime> }
pub type Watcher = PollWatcher;
impl PollWatcher {
    pub fn new(root: impl Into<PathBuf>) -> io::Result<Self> {
        let root = root.into();
        let snapshot = scan(&root)?;
        Ok(Self { root, snapshot })
    }
    pub fn root(&self) -> &Path { &self.root }
    /// Compare the directory to the previous snapshot and update it.
    pub fn poll(&mut self) -> io::Result<Vec<Change>> {
        let next = scan(&self.root)?;
        let mut changes = Vec::new();
        for (path, time) in &next {
            match self.snapshot.get(path) { None => changes.push(Change { path: path.clone(), kind: ChangeKind::Created }), Some(old) if old != time => changes.push(Change { path: path.clone(), kind: ChangeKind::Modified }), _ => {} }
        }
        for path in self.snapshot.keys() {
            if !next.contains_key(path) { changes.push(Change { path: path.clone(), kind: ChangeKind::Removed }); }
        }
        self.snapshot = next;
        Ok(changes)
    }
}

pub fn poll_interval() -> Duration { Duration::from_millis(250) }
fn scan(root: &Path) -> io::Result<BTreeMap<PathBuf, SystemTime>> {
    let mut result = BTreeMap::new();
    fn visit(dir: &Path, root: &Path, out: &mut BTreeMap<PathBuf, SystemTime>) -> io::Result<()> {
        for entry in fs::read_dir(dir)? {
            let entry = entry?; let path = entry.path(); let meta = entry.metadata()?;
            if meta.is_dir() { if entry.file_name() != ".git" { visit(&path, root, out)?; } }
            else if meta.is_file() { out.insert(path.strip_prefix(root).unwrap_or(&path).to_path_buf(), meta.modified().unwrap_or(SystemTime::UNIX_EPOCH)); }
        }
        Ok(())
    }
    visit(root, root, &mut result)?; Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn interval_is_reasonable() { assert_eq!(poll_interval(), Duration::from_millis(250)); }
}
