//! Typed ordered deltas between two committed windows.
//!
//! Both inputs are bounded to 300 messages, so this diff is bounded work per
//! flush regardless of how large the store is.
//!
//! Two classification rules carry the board's geometry contract:
//!
//! * **Eviction is not deletion.** A row trimmed off the window while still
//!   present in the store is [`VibeTimelineOpV1::EvictHead`] /
//!   [`VibeTimelineOpV1::EvictTail`], never `Remove`. Conflating them is how a
//!   scroll-back trim gets a delete animation.
//! * **Content is not geometry.** [`diff_snapshots`] separates changes that can
//!   move a pixel from changes that cannot, so the renderer's
//!   reconfigure-vs-relayout decision is data, not convention.

use std::collections::{HashMap, HashSet};

use crate::types::{VibeChangeMask, VibeMessageSnapshotV1, VibeTimelineOpV1};

/// Classifies what changed between two revisions of the same message.
pub fn diff_snapshots(old: &VibeMessageSnapshotV1, new: &VibeMessageSnapshotV1) -> VibeChangeMask {
    let mut mask = VibeChangeMask::NONE;

    if old.message_id != new.message_id || old.client_message_id != new.client_message_id {
        mask.insert(VibeChangeMask::IDENTITY);
    }
    if old.ts_ms != new.ts_ms {
        mask.insert(VibeChangeMask::ORDER);
    }
    if old.body != new.body {
        mask.insert(VibeChangeMask::BODY);
    }
    if old.delivery != new.delivery {
        mask.insert(VibeChangeMask::DELIVERY);
    }
    if old.reply != new.reply {
        mask.insert(VibeChangeMask::REPLY);
    }
    if old.edit != new.edit {
        mask.insert(VibeChangeMask::EDIT);
    }
    if old.service != new.service {
        mask.insert(VibeChangeMask::SERVICE);
    }
    if old.agent != new.agent {
        mask.insert(VibeChangeMask::AGENT);
    }
    if old.flags != new.flags {
        if old.flags.differs_geometrically(new.flags) {
            mask.insert(VibeChangeMask::FLAGS);
        } else {
            mask.insert(VibeChangeMask::FLAGS_COSMETIC);
        }
    }

    match (&old.media, &new.media) {
        (None, None) => {}
        (None, Some(_)) | (Some(_), None) => mask.insert(VibeChangeMask::MEDIA_GEOMETRY),
        (Some(a), Some(b)) => {
            // Anything that sizes the reserved frame.
            if a.natural_size != b.natural_size
                || a.duration_s != b.duration_s
                || a.mime != b.mime
                || a.envelope != b.envelope
                || a.identity != b.identity
            {
                mask.insert(VibeChangeMask::MEDIA_GEOMETRY);
            }
            // Anything that only repaints inside it.
            if a.thumbnail != b.thumbnail
                || a.remote_url != b.remote_url
                || a.waveform != b.waveform
                || a.file_name != b.file_name
                || a.byte_size != b.byte_size
            {
                mask.insert(VibeChangeMask::MEDIA_PIXELS);
            }
        }
    }

    mask
}

/// Produces the ordered ops that turn `old` into `new`.
///
/// `still_in_store` distinguishes a window trim from a real removal. Applying
/// the returned ops in order to `old` yields `new` exactly; `tests/replay.rs`
/// asserts that with a reference applier.
pub fn diff_windows(
    old: &[VibeMessageSnapshotV1],
    new: &[VibeMessageSnapshotV1],
    still_in_store: &dyn Fn(&str) -> bool,
) -> Vec<VibeTimelineOpV1> {
    let mut ops: Vec<VibeTimelineOpV1> = Vec::new();

    let new_index: HashMap<&str, usize> = new
        .iter()
        .enumerate()
        .map(|(i, m)| (m.message_id.as_str(), i))
        .collect();
    let old_index: HashMap<&str, usize> = old
        .iter()
        .enumerate()
        .map(|(i, m)| (m.message_id.as_str(), i))
        .collect();

    // Working copy of the ids currently rendered. Every op is generated against
    // this list and immediately applied to it, so emitted indices are always the
    // indices the consumer will see.
    let mut cur: Vec<String> = old.iter().map(|m| m.message_id.clone()).collect();

    // --- 0. identity remaps -------------------------------------------------
    // An optimistic row that was acknowledged under a server id remains the
    // same mounted row. Heal before classifying evictions/removals so the retired
    // id cannot be mistaken for a real deletion. If the canonical id was already
    // mounted as a separate row, this is a genuine duplicate collapse instead
    // and is intentionally left to the removal pass.
    let mut remapped_new_ids = HashSet::new();
    for message in new {
        let Some(previous_id) = message.client_message_id.as_deref() else {
            continue;
        };
        if previous_id == message.message_id
            || !old_index.contains_key(previous_id)
            || old_index.contains_key(message.message_id.as_str())
            || new_index.contains_key(previous_id)
        {
            continue;
        }
        let Some(index) = cur.iter().position(|id| id == previous_id) else {
            continue;
        };
        if cur.iter().any(|id| id == &message.message_id) {
            continue;
        }
        ops.push(VibeTimelineOpV1::RemapIdentity {
            index: index as u32,
            previous_message_id: previous_id.to_string(),
            message: message.clone(),
        });
        cur[index].clone_from(&message.message_id);
        remapped_new_ids.insert(message.message_id.as_str());
    }

    // --- 1. head/tail eviction ------------------------------------------------
    let head_evict = cur
        .iter()
        .take_while(|id| !new_index.contains_key(id.as_str()) && still_in_store(id))
        .count();
    if head_evict > 0 {
        ops.push(VibeTimelineOpV1::EvictHead {
            count: head_evict as u32,
        });
        cur.drain(..head_evict);
    }

    let tail_evict = cur
        .iter()
        .rev()
        .take_while(|id| !new_index.contains_key(id.as_str()) && still_in_store(id))
        .count();
    if tail_evict > 0 {
        ops.push(VibeTimelineOpV1::EvictTail {
            count: tail_evict as u32,
        });
        cur.truncate(cur.len() - tail_evict);
    }

    // --- 2. real removals -----------------------------------------------------
    // Descending index so earlier indices stay valid as we go.
    let removals: Vec<usize> = cur
        .iter()
        .enumerate()
        .filter(|(_, id)| !new_index.contains_key(id.as_str()))
        .map(|(i, _)| i)
        .collect();
    for i in removals.into_iter().rev() {
        let removed = cur.remove(i);
        ops.push(VibeTimelineOpV1::Remove {
            index: i as u32,
            message_id: removed,
        });
    }

    // --- 3. moves and inserts -------------------------------------------------
    for (target, message) in new.iter().enumerate() {
        let id = message.message_id.as_str();
        if cur.get(target).is_some_and(|current| current == id) {
            continue;
        }
        match cur.iter().skip(target).position(|c| c == id) {
            Some(offset) => {
                let from = target + offset;
                ops.push(VibeTimelineOpV1::Move {
                    from: from as u32,
                    to: target as u32,
                    message_id: id.to_string(),
                });
                let moved = cur.remove(from);
                cur.insert(target, moved);
            }
            None => {
                ops.push(VibeTimelineOpV1::Insert {
                    index: target as u32,
                    message: message.clone(),
                });
                cur.insert(target, id.to_string());
            }
        }
    }

    // --- 4. content and geometry updates -------------------------------------
    for (i, message) in new.iter().enumerate() {
        if remapped_new_ids.contains(message.message_id.as_str()) {
            continue; // RemapIdentity already carried the complete replacement.
        }
        let Some(old_pos) = old_index.get(message.message_id.as_str()) else {
            continue; // freshly inserted; the Insert op already carried it
        };
        let previous = &old[*old_pos];
        if previous.content_hash == message.content_hash && previous == message {
            continue;
        }
        let changed = diff_snapshots(previous, message);
        if changed.is_empty() {
            continue;
        }
        if changed.is_geometry_relevant() {
            ops.push(VibeTimelineOpV1::UpdateGeometry {
                index: i as u32,
                message: message.clone(),
                changed,
            });
        } else {
            ops.push(VibeTimelineOpV1::UpdateContent {
                index: i as u32,
                message: message.clone(),
                changed,
            });
        }
    }

    ops
}

/// Reference applier.
///
/// Exists so tests can assert `apply(old, diff(old, new)) == new` rather than
/// eyeballing op sequences, and so the iOS/Android adapters have an executable
/// specification of what each op means.
pub fn apply_ops(
    window: &mut Vec<VibeMessageSnapshotV1>,
    ops: &[VibeTimelineOpV1],
) -> Result<(), VibeApplyError> {
    for op in ops {
        match op {
            VibeTimelineOpV1::EvictHead { count } => {
                let n = *count as usize;
                if n > window.len() {
                    return Err(VibeApplyError::OutOfRange);
                }
                window.drain(..n);
            }
            VibeTimelineOpV1::EvictTail { count } => {
                let n = *count as usize;
                if n > window.len() {
                    return Err(VibeApplyError::OutOfRange);
                }
                window.truncate(window.len() - n);
            }
            VibeTimelineOpV1::Remove { index, message_id } => {
                let i = *index as usize;
                if i >= window.len() {
                    return Err(VibeApplyError::OutOfRange);
                }
                if window[i].message_id != *message_id {
                    return Err(VibeApplyError::IdentityMismatch);
                }
                window.remove(i);
            }
            VibeTimelineOpV1::RemapIdentity {
                index,
                previous_message_id,
                message,
            } => {
                let i = *index as usize;
                if i >= window.len() {
                    return Err(VibeApplyError::OutOfRange);
                }
                if window[i].message_id != *previous_message_id {
                    return Err(VibeApplyError::IdentityMismatch);
                }
                if window.iter().enumerate().any(|(candidate, mounted)| {
                    candidate != i && mounted.message_id == message.message_id
                }) {
                    return Err(VibeApplyError::IdentityMismatch);
                }
                window[i] = message.clone();
            }
            VibeTimelineOpV1::Insert { index, message } => {
                let i = *index as usize;
                if i > window.len() {
                    return Err(VibeApplyError::OutOfRange);
                }
                window.insert(i, message.clone());
            }
            VibeTimelineOpV1::Move {
                from,
                to,
                message_id,
            } => {
                let (f, t) = (*from as usize, *to as usize);
                if f >= window.len() || t > window.len() {
                    return Err(VibeApplyError::OutOfRange);
                }
                if window[f].message_id != *message_id {
                    return Err(VibeApplyError::IdentityMismatch);
                }
                let m = window.remove(f);
                window.insert(t, m);
            }
            VibeTimelineOpV1::UpdateContent { index, message, .. }
            | VibeTimelineOpV1::UpdateGeometry { index, message, .. } => {
                let i = *index as usize;
                if i >= window.len() {
                    return Err(VibeApplyError::OutOfRange);
                }
                if window[i].message_id != message.message_id {
                    return Err(VibeApplyError::IdentityMismatch);
                }
                window[i] = message.clone();
            }
        }
    }
    Ok(())
}

/// Why a reference apply failed. Any of these in a test means the diff is wrong.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VibeApplyError {
    OutOfRange,
    IdentityMismatch,
}

impl std::fmt::Display for VibeApplyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::OutOfRange => f.write_str("op index out of range"),
            Self::IdentityMismatch => f.write_str("op identity does not match the target row"),
        }
    }
}

impl std::error::Error for VibeApplyError {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{
        VibeDisplayStatus, VibeMediaEnvelope, VibeMediaRef, VibeMessageFlags, VibeSize,
        VibeThumbHandle,
    };

    fn msg(id: &str, ts: i64, text: &str) -> VibeMessageSnapshotV1 {
        VibeMessageSnapshotV1::text_message("c", id, ts, "u", false, text)
    }

    fn all_in_store(_: &str) -> bool {
        true
    }

    fn none_in_store(_: &str) -> bool {
        false
    }

    fn round_trip(
        old: &[VibeMessageSnapshotV1],
        new: &[VibeMessageSnapshotV1],
        still: &dyn Fn(&str) -> bool,
    ) -> Vec<VibeTimelineOpV1> {
        let ops = diff_windows(old, new, still);
        let mut applied = old.to_vec();
        apply_ops(&mut applied, &ops).expect("ops must apply cleanly");
        assert_eq!(
            applied,
            new.to_vec(),
            "diff did not reproduce the new window"
        );
        ops
    }

    #[test]
    fn identical_windows_produce_no_ops() {
        let w = vec![msg("a", 1, "x"), msg("b", 2, "y")];
        assert!(round_trip(&w, &w, &all_in_store).is_empty());
    }

    #[test]
    fn tail_append_is_a_single_insert() {
        let old = vec![msg("a", 1, "x")];
        let new = vec![msg("a", 1, "x"), msg("b", 2, "y")];
        let ops = round_trip(&old, &new, &all_in_store);
        assert_eq!(ops.len(), 1);
        assert!(matches!(ops[0], VibeTimelineOpV1::Insert { index: 1, .. }));
    }

    #[test]
    fn window_trim_is_eviction_not_deletion() {
        let old = vec![msg("a", 1, "x"), msg("b", 2, "y"), msg("c", 3, "z")];
        let new = vec![msg("b", 2, "y"), msg("c", 3, "z"), msg("d", 4, "w")];
        let ops = round_trip(&old, &new, &all_in_store);
        assert!(matches!(ops[0], VibeTimelineOpV1::EvictHead { count: 1 }));
        assert!(ops
            .iter()
            .all(|o| !matches!(o, VibeTimelineOpV1::Remove { .. })));
    }

    #[test]
    fn scroll_back_prepend_evicts_the_tail() {
        let old = vec![msg("c", 3, "z"), msg("d", 4, "w")];
        let new = vec![msg("a", 1, "x"), msg("b", 2, "y"), msg("c", 3, "z")];
        let ops = round_trip(&old, &new, &all_in_store);
        assert!(ops
            .iter()
            .any(|o| matches!(o, VibeTimelineOpV1::EvictTail { count: 1 })));
    }

    #[test]
    fn a_real_delete_is_a_remove() {
        let old = vec![msg("a", 1, "x"), msg("b", 2, "y")];
        let new = vec![msg("a", 1, "x")];
        let ops = round_trip(&old, &new, &none_in_store);
        assert_eq!(ops.len(), 1);
        assert!(matches!(
            &ops[0],
            VibeTimelineOpV1::Remove { index: 1, message_id } if message_id == "b"
        ));
    }

    #[test]
    fn settle_slot_reorder_is_a_move_not_remove_insert() {
        let old = vec![msg("a", 1, "x"), msg("b", 2, "y"), msg("c", 3, "z")];
        // `c` adopts an earlier slot and moves to the front.
        let new = vec![msg("c", 0, "z"), msg("a", 1, "x"), msg("b", 2, "y")];
        let ops = round_trip(&old, &new, &all_in_store);
        assert!(ops
            .iter()
            .any(|o| matches!(o, VibeTimelineOpV1::Move { from: 2, to: 0, .. })));
        assert!(ops
            .iter()
            .all(|o| !matches!(o, VibeTimelineOpV1::Remove { .. })));
    }

    #[test]
    fn optimistic_heal_is_an_identity_remap_not_remove_insert() {
        let old = vec![msg("before", 1, "x"), msg("local-1", 2, "sending")];
        let mut healed = msg("server-1", 2, "sending");
        healed.client_message_id = Some("local-1".into());
        healed.rehash();
        let new = vec![msg("before", 1, "x"), healed];

        let ops = round_trip(&old, &new, &none_in_store);
        assert!(matches!(
            &ops[0],
            VibeTimelineOpV1::RemapIdentity {
                index: 1,
                previous_message_id,
                message,
            } if previous_message_id == "local-1" && message.message_id == "server-1"
        ));
        assert!(ops.iter().all(|op| !matches!(
            op,
            VibeTimelineOpV1::Remove { .. } | VibeTimelineOpV1::Insert { .. }
        )));
    }

    #[test]
    fn identity_remap_can_be_followed_by_a_move_without_reinsertion() {
        let old = vec![msg("a", 10, "a"), msg("local-1", 30, "sending")];
        let mut healed = msg("server-1", 5, "settled");
        healed.client_message_id = Some("local-1".into());
        healed.rehash();
        let new = vec![healed, msg("a", 10, "a")];

        let ops = round_trip(&old, &new, &none_in_store);
        assert!(ops
            .iter()
            .any(|op| matches!(op, VibeTimelineOpV1::RemapIdentity { .. })));
        assert!(ops
            .iter()
            .any(|op| matches!(op, VibeTimelineOpV1::Move { .. })));
        assert!(ops.iter().all(|op| !matches!(
            op,
            VibeTimelineOpV1::Remove { .. } | VibeTimelineOpV1::Insert { .. }
        )));
    }

    #[test]
    fn canonical_row_already_present_collapses_the_duplicate_as_a_remove() {
        let old = vec![msg("local-1", 1, "x"), msg("server-1", 2, "x")];
        let mut canonical = msg("server-1", 2, "x");
        canonical.client_message_id = Some("local-1".into());
        canonical.rehash();

        let ops = round_trip(&old, &[canonical], &none_in_store);
        assert!(ops
            .iter()
            .any(|op| matches!(op, VibeTimelineOpV1::Remove { message_id, .. } if message_id == "local-1")));
        assert!(ops
            .iter()
            .all(|op| !matches!(op, VibeTimelineOpV1::RemapIdentity { .. })));
    }

    #[test]
    fn a_receipt_change_is_content_only() {
        let old = vec![msg("a", 1, "x")];
        let mut updated = msg("a", 1, "x");
        updated.delivery.display = VibeDisplayStatus::Read;
        updated.rehash();
        let ops = round_trip(&old, &[updated], &all_in_store);
        assert_eq!(ops.len(), 1);
        match &ops[0] {
            VibeTimelineOpV1::UpdateContent { changed, .. } => {
                assert!(changed.contains(VibeChangeMask::DELIVERY));
                assert!(!changed.is_geometry_relevant());
            }
            other => panic!("expected content update, got {}", other.kind_label()),
        }
    }

    #[test]
    fn an_edit_is_geometry_relevant() {
        let old = vec![msg("a", 1, "short")];
        let new = vec![msg("a", 1, "much much much longer text")];
        let ops = round_trip(&old, &new, &all_in_store);
        assert!(matches!(
            &ops[0],
            VibeTimelineOpV1::UpdateGeometry { changed, .. } if changed.contains(VibeChangeMask::BODY)
        ));
    }

    #[test]
    fn late_thumbnail_arrival_does_not_change_geometry() {
        let media = |thumb: Option<&str>| VibeMediaRef {
            identity: "cdn/x.jpg".into(),
            remote_url: Some("https://cdn/x.jpg".into()),
            file_name: None,
            mime: Some("image/jpeg".into()),
            byte_size: Some(1024),
            natural_size: Some(VibeSize {
                width: 1600,
                height: 900,
            }),
            duration_s: None,
            waveform: Vec::new(),
            thumbnail: thumb.map(|t| VibeThumbHandle {
                identity: t.into(),
                size: None,
                placeholder: None,
            }),
            envelope: VibeMediaEnvelope::Plain,
        };

        let mut before = msg("a", 1, "");
        before.media = Some(media(None));
        before.rehash();
        let mut after = msg("a", 1, "");
        after.media = Some(media(Some("thumb-1")));
        after.rehash();

        let ops = round_trip(&[before], &[after], &all_in_store);
        assert_eq!(ops.len(), 1);
        match &ops[0] {
            VibeTimelineOpV1::UpdateContent { changed, .. } => {
                assert!(changed.contains(VibeChangeMask::MEDIA_PIXELS));
                assert!(!changed.contains(VibeChangeMask::MEDIA_GEOMETRY));
            }
            other => panic!(
                "late thumbnail must not relayout, got {}",
                other.kind_label()
            ),
        }
    }

    #[test]
    fn natural_size_arriving_late_is_geometry_relevant() {
        let media = |size: Option<VibeSize>| VibeMediaRef {
            identity: "cdn/x.jpg".into(),
            remote_url: None,
            file_name: None,
            mime: Some("image/jpeg".into()),
            byte_size: None,
            natural_size: size,
            duration_s: None,
            waveform: Vec::new(),
            thumbnail: None,
            envelope: VibeMediaEnvelope::Plain,
        };
        let mut before = msg("a", 1, "");
        before.media = Some(media(None));
        before.rehash();
        let mut after = msg("a", 1, "");
        after.media = Some(media(Some(VibeSize {
            width: 100,
            height: 200,
        })));
        after.rehash();

        let ops = round_trip(&[before], &[after], &all_in_store);
        assert!(matches!(
            &ops[0],
            VibeTimelineOpV1::UpdateGeometry { changed, .. }
                if changed.contains(VibeChangeMask::MEDIA_GEOMETRY)
        ));
    }

    #[test]
    fn a_cosmetic_flag_flip_is_content_only() {
        let old = vec![msg("a", 1, "x")];
        let mut new = msg("a", 1, "x");
        new.flags.insert(VibeMessageFlags::PINNED);
        new.rehash();
        let ops = round_trip(&old, &[new], &all_in_store);
        assert!(matches!(
            &ops[0],
            VibeTimelineOpV1::UpdateContent { changed, .. }
                if changed.contains(VibeChangeMask::FLAGS_COSMETIC)
        ));
    }

    #[test]
    fn a_streaming_flag_flip_is_geometry_relevant() {
        let old = vec![msg("a", 1, "x")];
        let mut new = msg("a", 1, "x");
        new.flags.insert(VibeMessageFlags::STREAMING);
        new.rehash();
        let ops = round_trip(&old, &[new], &all_in_store);
        assert!(matches!(
            &ops[0],
            VibeTimelineOpV1::UpdateGeometry { changed, .. }
                if changed.contains(VibeChangeMask::FLAGS)
        ));
    }

    #[test]
    fn a_complete_replacement_still_round_trips() {
        let old = vec![msg("a", 1, "x"), msg("b", 2, "y"), msg("c", 3, "z")];
        let new = vec![msg("x", 9, "1"), msg("y", 10, "2")];
        round_trip(&old, &new, &none_in_store);
    }

    #[test]
    fn interleaved_insert_delete_and_update_round_trips() {
        let old = vec![
            msg("a", 1, "x"),
            msg("b", 2, "y"),
            msg("c", 3, "z"),
            msg("d", 4, "w"),
        ];
        let new = vec![
            msg("a", 1, "x"),
            msg("b2", 2, "new"),
            msg("c", 3, "z EDITED"),
            msg("e", 5, "e"),
        ];
        round_trip(&old, &new, &|id| id == "d");
    }
}
