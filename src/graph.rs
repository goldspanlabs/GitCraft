use std::collections::{BTreeMap, BTreeSet, VecDeque};

/// A commit and its direct parents.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommitNode {
    pub id: String,
    pub message: String,
    pub parents: Vec<String>,
}

/// A directed commit graph. Edges point from a commit to its parents.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CommitGraph {
    nodes: BTreeMap<String, CommitNode>,
}

impl CommitGraph {
    pub fn new() -> Self { Self::default() }

    pub fn add(&mut self, node: CommitNode) {
        self.nodes.insert(node.id.clone(), node);
    }

    pub fn add_commit(&mut self, id: impl Into<String>, message: impl Into<String>, parents: impl IntoIterator<Item = impl Into<String>>) {
        self.add(CommitNode { id: id.into(), message: message.into(), parents: parents.into_iter().map(Into::into).collect() });
    }

    pub fn get(&self, id: &str) -> Option<&CommitNode> { self.nodes.get(id) }
    pub fn len(&self) -> usize { self.nodes.len() }
    pub fn is_empty(&self) -> bool { self.nodes.is_empty() }
    pub fn iter(&self) -> impl Iterator<Item = &CommitNode> { self.nodes.values() }

    /// Commits with no known children (usually the current tips).
    pub fn heads(&self) -> Vec<&CommitNode> {
        let parents: BTreeSet<_> = self.nodes.values().flat_map(|n| n.parents.iter()).collect();
        self.nodes.values().filter(|n| !parents.contains(&n.id)).collect()
    }

    pub fn roots(&self) -> Vec<&CommitNode> {
        self.nodes.values().filter(|n| n.parents.iter().all(|p| !self.nodes.contains_key(p))).collect()
    }

    /// Returns reachable ancestors, nearest first, excluding `id`.
    pub fn ancestors(&self, id: &str) -> Vec<&CommitNode> {
        let mut result = Vec::new();
        let mut queue: VecDeque<String> = self.get(id).into_iter().flat_map(|n| n.parents.clone()).collect();
        let mut seen = BTreeSet::new();
        while let Some(current) = queue.pop_front() {
            if !seen.insert(current.clone()) { continue; }
            if let Some(node) = self.get(&current) {
                queue.extend(node.parents.iter().cloned());
                result.push(node);
            }
        }
        result
    }

    /// A deterministic parent-before-child ordering of all known nodes.
    pub fn topological(&self) -> Vec<&CommitNode> {
        let mut indegree: BTreeMap<&str, usize> = self.nodes.values().map(|n| {
            (n.id.as_str(), n.parents.iter().filter(|p| self.nodes.contains_key(*p)).count())
        }).collect();
        let mut queue: VecDeque<String> = self.nodes.values().filter(|n| n.parents.iter().all(|p| !self.nodes.contains_key(p))).map(|n| n.id.clone()).collect();
        let mut out = Vec::new();
        while let Some(id) = queue.pop_front() {
            if let Some(node) = self.get(&id) {
                out.push(node);
                for child in self.nodes.values().filter(|n| n.parents.iter().any(|p| p == &id)) {
                    if let Some(count) = indegree.get_mut(child.id.as_str()) {
                        *count -= 1;
                        if *count == 0 { queue.push_back(child.id.clone()); }
                    }
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn traverses_and_orders_commits() {
        let mut g = CommitGraph::new();
        g.add_commit("c", "third", ["b"]);
        g.add_commit("b", "second", ["a"]);
        g.add_commit("a", "first", [] as [&str; 0]);
        assert_eq!(g.ancestors("c").iter().map(|n| n.id.as_str()).collect::<Vec<_>>(), ["b", "a"]);
        assert_eq!(g.topological().iter().map(|n| n.id.as_str()).collect::<Vec<_>>(), ["a", "b", "c"]);
    }
}
