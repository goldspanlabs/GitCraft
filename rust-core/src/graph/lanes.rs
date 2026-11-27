use crate::{CommitRow, GraphEdge, RefBadge};

#[derive(Clone, Debug)]
pub(crate) struct RawCommit {
    pub oid: gix::ObjectId,
    pub parents: Vec<gix::ObjectId>,
    pub summary: String,
    pub author_name: String,
    pub author_email: String,
    pub timestamp: i64,
}

/// An edge drawn from `from` to `to` in the row, in lane `color`.
fn edge(from: usize, to: usize, is_merge: bool, color: u8) -> GraphEdge {
    GraphEdge {
        from_lane: from as u32,
        to_lane: to as u32,
        is_merge,
        color_idx: color,
    }
}

#[derive(Clone, Copy, Debug)]
struct LaneSlot {
    oid: gix::ObjectId,
    color: u8,
}

/// Tracks active graph lanes and color assignments as commits are walked newest-first.
#[derive(Default)]
pub(crate) struct LaneState {
    slots: Vec<Option<LaneSlot>>,
    next_color: u8,
}

impl LaneState {
    fn alloc_color(&mut self) -> u8 {
        let color = self.next_color % 8;
        self.next_color = self.next_color.wrapping_add(1);
        color
    }

    fn place_in_free_slot(&mut self, oid: gix::ObjectId, preferred: Option<usize>) -> (usize, u8) {
        let idx = preferred.unwrap_or_else(|| {
            self.slots.push(None);
            self.slots.len() - 1
        });
        let color = self.alloc_color();
        self.slots[idx] = Some(LaneSlot { oid, color });
        (idx, color)
    }

    fn first_free_slot(&self) -> Option<usize> {
        self.slots.iter().position(Option::is_none)
    }

    fn nearest_free_slot(&self, origin: usize) -> Option<usize> {
        self.slots
            .iter()
            .enumerate()
            .filter(|(_, slot)| slot.is_none())
            .min_by_key(|(idx, _)| idx.abs_diff(origin))
            .map(|(idx, _)| idx)
    }

    pub(crate) fn assign_commit(&mut self, commit: &RawCommit, refs: Vec<RefBadge>) -> CommitRow {
        let mut edges: Vec<GraphEdge> = Vec::new();

        // 1. Locate commit.oid in active slots; collapse converging duplicates.
        let matching_slots: Vec<usize> = self
            .slots
            .iter()
            .enumerate()
            .filter_map(|(idx, slot)| slot.is_some_and(|s| s.oid == commit.oid).then_some(idx))
            .collect();

        let (commit_lane, commit_color) = if let Some(&first_slot) = matching_slots.first() {
            let color = self.slots[first_slot].expect("matched slot is Some").color;
            for &dup in &matching_slots[1..] {
                let dup_color = self.slots[dup].expect("matched dup slot is Some").color;
                self.slots[dup] = None;
                edges.push(edge(dup, first_slot, true, dup_color));
            }
            (first_slot, color)
        } else {
            // Branch tip: place in first free slot or append a new lane.
            let free = self.first_free_slot();
            self.place_in_free_slot(commit.oid, free)
        };

        // 2. Emit vertical pass-through edges for all other occupied slots.
        for (idx, slot) in self.slots.iter().enumerate() {
            if idx != commit_lane {
                if let Some(s) = slot {
                    edges.push(edge(idx, idx, false, s.color));
                }
            }
        }

        // 3. Route parents[0] into slots[commit_lane] to keep mainline straight.
        if let Some(&first_parent) = commit.parents.first() {
            self.slots[commit_lane] = Some(LaneSlot {
                oid: first_parent,
                color: commit_color,
            });
            edges.push(edge(commit_lane, commit_lane, false, commit_color));
        } else {
            self.slots[commit_lane] = None;
        }

        // 4. Route parents[1..] (merge parents) into existing matching lanes or nearest free slot.
        for &parent_oid in commit.parents.iter().skip(1) {
            let (target_lane, edge_color) = if let Some((existing, slot)) = self
                .slots
                .iter()
                .enumerate()
                .find_map(|(i, s)| s.filter(|s| s.oid == parent_oid).map(|s| (i, s)))
            {
                (existing, slot.color)
            } else {
                let free = self.nearest_free_slot(commit_lane);
                self.place_in_free_slot(parent_oid, free)
            };

            edges.push(edge(commit_lane, target_lane, true, edge_color));
        }

        // Compute max_lanes across active lanes and emitted edges before trimming.
        let mut max_lanes = self.slots.len().max(commit_lane + 1);
        for edge in &edges {
            max_lanes = max_lanes
                .max(edge.from_lane as usize + 1)
                .max(edge.to_lane as usize + 1);
        }

        // 5. Trim trailing None slots to keep max_lanes compact.
        while self.slots.last().is_some_and(Option::is_none) {
            self.slots.pop();
        }

        let oid_hex = commit.oid.to_hex().to_string();
        let short_oid = super::short_oid(&oid_hex);

        CommitRow {
            oid_hex,
            short_oid,
            summary: commit.summary.clone(),
            author_name: commit.author_name.clone(),
            author_email: commit.author_email.clone(),
            timestamp: commit.timestamp,
            lane: commit_lane as u32,
            color_idx: commit_color,
            max_lanes: max_lanes as u32,
            edges,
            refs,
            is_remote_only: false,
            is_unpushed: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn oid(byte: u8) -> gix::ObjectId {
        gix::ObjectId::from_bytes_or_panic(&[byte; 20])
    }

    fn raw(id: u8, parents: &[u8], summary: &str) -> RawCommit {
        RawCommit {
            oid: oid(id),
            parents: parents.iter().map(|&p| oid(p)).collect(),
            summary: summary.to_owned(),
            author_name: "Tester".to_owned(),
            author_email: "tester@example.com".to_owned(),
            timestamp: 1_700_000_000 + id as i64,
        }
    }

    #[test]
    fn linear_history_uses_single_straight_lane() {
        let mut lanes = LaneState::default();

        let c3 = lanes.assign_commit(&raw(3, &[2], "c3"), vec![]);
        let c2 = lanes.assign_commit(&raw(2, &[1], "c2"), vec![]);
        let c1 = lanes.assign_commit(&raw(1, &[], "c1"), vec![]);

        assert_eq!(c3.lane, 0);
        assert_eq!(c3.max_lanes, 1);
        assert_eq!(c3.color_idx, c2.color_idx);
        assert_eq!(c2.lane, 0);
        assert_eq!(c2.max_lanes, 1);
        assert_eq!(c1.lane, 0);
        assert_eq!(c1.color_idx, c3.color_idx);
        assert!(lanes.slots.is_empty());
    }

    #[test]
    fn branch_creation_and_merge_convergence_lane_geometry() {
        // History (newest first):
        //   c4 (merge: parents [c3, c2]) on main
        //   c3 (parent [c1]) on main
        //   c2 (parent [c1]) on feature
        //   c1 (root)
        let mut lanes = LaneState::default();

        let c4 = lanes.assign_commit(&raw(4, &[3, 2], "Merge feature"), vec![]);
        assert_eq!(c4.lane, 0);
        assert_eq!(c4.max_lanes, 2);
        // Outgoing merge edge from lane 0 -> lane 1
        assert!(c4
            .edges
            .iter()
            .any(|e| e.from_lane == 0 && e.to_lane == 1 && e.is_merge));

        let c3 = lanes.assign_commit(&raw(3, &[1], "Main work"), vec![]);
        assert_eq!(c3.lane, 0);
        assert_eq!(c3.max_lanes, 2);
        // Lane 1 should pass straight through while lane 0 is at c3
        assert!(c3
            .edges
            .iter()
            .any(|e| e.from_lane == 1 && e.to_lane == 1 && !e.is_merge));

        let c2 = lanes.assign_commit(&raw(2, &[1], "Feature work"), vec![]);
        assert_eq!(c2.lane, 1);
        assert_eq!(c2.max_lanes, 2);

        // Now both lane 0 and lane 1 point to c1: should converge onto lane 0.
        let c1 = lanes.assign_commit(&raw(1, &[], "Initial"), vec![]);
        assert_eq!(c1.lane, 0);
        assert_eq!(c1.max_lanes, 2);
        assert!(c1
            .edges
            .iter()
            .any(|e| e.from_lane == 1 && e.to_lane == 0 && e.is_merge));
        assert!(lanes.slots.is_empty());
    }
    #[test]
    fn octopus_merge_fans_out_one_edge_per_extra_parent() {
        // o5 merges [o1, o2, o3, o4]; each parent is a separate root-less branch tip.
        let mut lanes = LaneState::default();

        let merge = lanes.assign_commit(&raw(5, &[1, 2, 3, 4], "Octopus"), vec![]);
        assert_eq!(merge.lane, 0);
        assert_eq!(merge.max_lanes, 4);
        for target in 1..=3u32 {
            assert!(
                merge
                    .edges
                    .iter()
                    .any(|e| e.from_lane == 0 && e.to_lane == target && e.is_merge),
                "missing merge edge to lane {target}"
            );
        }
        // Mainline continues straight on lane 0.
        assert!(merge
            .edges
            .iter()
            .any(|e| e.from_lane == 0 && e.to_lane == 0 && !e.is_merge));
        // Each branch gets its own color.
        let colors: std::collections::HashSet<u8> =
            merge.edges.iter().map(|e| e.color_idx).collect();
        assert_eq!(colors.len(), 4);

        // Parents land on the lanes their edges promised.
        let p2 = lanes.assign_commit(&raw(2, &[], "p2"), vec![]);
        assert_eq!(p2.lane, 1);
        let p3 = lanes.assign_commit(&raw(3, &[], "p3"), vec![]);
        assert_eq!(p3.lane, 2);
        let p4 = lanes.assign_commit(&raw(4, &[], "p4"), vec![]);
        assert_eq!(p4.lane, 3);
        let p1 = lanes.assign_commit(&raw(1, &[], "p1"), vec![]);
        assert_eq!(p1.lane, 0);
        assert!(lanes.slots.is_empty());
    }

    #[test]
    fn merge_into_an_already_tracked_lane_reuses_it() {
        // Two tips (c5 -> c2, c4 merge [c3, c2]) share c2, so the merge edge targets the existing lane.
        let mut lanes = LaneState::default();

        let c5 = lanes.assign_commit(&raw(5, &[2], "Other tip"), vec![]);
        assert_eq!(c5.lane, 0);
        let c4 = lanes.assign_commit(&raw(4, &[3, 2], "Merge"), vec![]);
        assert_eq!(c4.lane, 1);
        let to_existing = c4
            .edges
            .iter()
            .find(|e| e.from_lane == 1 && e.is_merge)
            .expect("merge edge");
        assert_eq!(to_existing.to_lane, 0);
        assert_eq!(c4.max_lanes, 2);
    }

    #[test]
    fn independent_branch_tips_get_separate_lanes_and_free_slots_are_reused() {
        let mut lanes = LaneState::default();

        let a = lanes.assign_commit(&raw(10, &[], "tip a (root)"), vec![]);
        assert_eq!(a.lane, 0);
        assert!(lanes.slots.is_empty());

        // Two live tips side by side.
        let b = lanes.assign_commit(&raw(20, &[19], "tip b"), vec![]);
        let c = lanes.assign_commit(&raw(30, &[29], "tip c"), vec![]);
        assert_eq!((b.lane, c.lane), (0, 1));
        assert_ne!(b.color_idx, c.color_idx);

        // Finishing lane 0 frees it, so the next new tip reuses lane 0.
        lanes.assign_commit(&raw(19, &[], "end b"), vec![]);
        let d = lanes.assign_commit(&raw(40, &[], "tip d"), vec![]);
        assert_eq!(d.lane, 0);
    }

    #[test]
    fn colors_wrap_after_eight_lanes() {
        let mut lanes = LaneState::default();
        let rows: Vec<_> = (1..=9u8)
            .map(|i| lanes.assign_commit(&raw(i, &[100 + i], "tip"), vec![]))
            .collect();
        let colors: Vec<u8> = rows.iter().map(|r| r.color_idx).collect();
        assert_eq!(colors, vec![0, 1, 2, 3, 4, 5, 6, 7, 0]);
    }
}
