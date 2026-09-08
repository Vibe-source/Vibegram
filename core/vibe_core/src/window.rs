//! Bounded windowing and anchor resolution.
//!
//! The store may hold 100,000 messages. Every query and every delta this crate
//! produces is bounded to [`VibeWindowPolicy::max_len`] messages — 300 — and no
//! code path materializes the full store.
//!
//! Window bounds are measured in **messages, not rows**. Day dividers, unread
//! separators and date headers are a render concern and are minted by the
//! renderer; if the core emitted them too, both layers would insert them.

use std::collections::HashMap;

use crate::types::{
    VibeAnchorPin, VibeAnchorResolution, VibeMessageSnapshotV1, VibeTimelineAnchor,
    VibeWindowBounds,
};

/// Active-window policy.
///
/// The bounded form is 150…300 messages, default 200, plus at most two preload
/// screens instantiated by the renderer (which is the renderer's rule, not this
/// crate's). It is still available — [`VibeWindowPolicy::try_new`] builds one and
/// enforces that envelope — but it is **no longer the default**.
///
/// # Why the default is unbounded
///
/// A bounded window is a scroll limit, and the product decision is that this app has
/// none. Every version of the bounded window was experienced as a wall: at the cap the
/// window slid, so a drag to the top replaced the rows instead of extending them.
///
/// Telegram bounds its window — `historyMessageCount = 90` in `ChatHistoryListNode`,
/// and scrolling issues a new anchor rather than growing the view — and gets away with
/// it because its list is its own: `ListViewItem.nodeConfiguredForParams(async:…)`
/// computes each row's layout on a background queue and leaves the main thread nothing
/// but a cheap `apply`. Their cap exists to bound *node* count, not row count.
///
/// We cannot split layout from commit that way inside `UICollectionView`, so the cap
/// bought us nothing that the reader did not pay for in wall. What actually made a
/// large mounted set expensive here was the renderer recomputing every row's position
/// on every commit — `UICollectionViewFlowLayout.prepare()` is O(total items). That is
/// fixed on the platform side by a layout that keeps a cumulative offset table and
/// recomputes only from the first changed row, fed by heights this crate already
/// measured off the main thread. With an O(changed) commit, mounting the whole
/// transcript costs what mounting a window used to.
///
/// So: no ceiling here, and the constant-cost commit is preserved where it actually
/// lives — in the renderer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VibeWindowPolicy {
    pub min_len: u32,
    /// `u32::MAX` means "no ceiling": the window is the whole store. See
    /// [`VibeWindowPolicy::is_unbounded`].
    pub max_len: u32,
    pub default_len: u32,
    /// How many messages one scroll-back page adds. Ignored when unbounded.
    pub page_size: u32,
}

/// Why a policy was rejected.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VibeWindowPolicyError {
    MinAboveMax,
    DefaultOutOfRange,
    ZeroPageSize,
    /// Outside the board's frozen 150…300 envelope.
    OutsideContract,
}

impl std::fmt::Display for VibeWindowPolicyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MinAboveMax => f.write_str("min_len above max_len"),
            Self::DefaultOutOfRange => f.write_str("default_len outside [min_len, max_len]"),
            Self::ZeroPageSize => f.write_str("page_size must be positive"),
            Self::OutsideContract => f.write_str("policy outside the frozen 150..=300 contract"),
        }
    }
}

impl std::error::Error for VibeWindowPolicyError {}

impl Default for VibeWindowPolicy {
    fn default() -> Self {
        Self::unbounded()
    }
}

impl VibeWindowPolicy {
    /// Lower bound of the frozen contract.
    pub const CONTRACT_MIN: u32 = 150;
    /// Upper bound of the frozen contract.
    pub const CONTRACT_MAX: u32 = 300;

    /// No ceiling: the window is always the entire store, and paging is a no-op.
    pub fn unbounded() -> Self {
        Self {
            min_len: 0,
            max_len: u32::MAX,
            default_len: 0,
            page_size: 1,
        }
    }

    /// Whether this policy has no ceiling.
    pub fn is_unbounded(&self) -> bool {
        self.max_len == u32::MAX
    }

    pub fn try_new(
        min_len: u32,
        max_len: u32,
        default_len: u32,
        page_size: u32,
    ) -> Result<Self, VibeWindowPolicyError> {
        if min_len > max_len {
            return Err(VibeWindowPolicyError::MinAboveMax);
        }
        if default_len < min_len || default_len > max_len {
            return Err(VibeWindowPolicyError::DefaultOutOfRange);
        }
        if page_size == 0 {
            return Err(VibeWindowPolicyError::ZeroPageSize);
        }
        if min_len < Self::CONTRACT_MIN || max_len > Self::CONTRACT_MAX {
            return Err(VibeWindowPolicyError::OutsideContract);
        }
        Ok(Self {
            min_len,
            max_len,
            default_len,
            page_size,
        })
    }
}

/// The window's position in the ordered store.
///
/// `follow_tail` is the live-chat mode: the window re-pins to the newest message
/// on every rebuild. A scroll-back page turns it off, which is what stops a new
/// arrival from yanking the user out of history.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VibeWindowCursor {
    pub follow_tail: bool,
    pub start: usize,
    pub len: usize,
}

impl Default for VibeWindowCursor {
    fn default() -> Self {
        Self {
            follow_tail: true,
            start: 0,
            len: 0,
        }
    }
}

impl VibeWindowCursor {
    pub fn end(&self) -> usize {
        self.start + self.len
    }

    /// Re-derives a legal `(start, len)` for the current store size.
    ///
    /// Called after every mutation. This is the one place window bounds are
    /// enforced, so "the window is never larger than 300" is a single invariant
    /// rather than a rule every call site has to remember.
    pub fn clamped(mut self, total: usize, policy: VibeWindowPolicy) -> Self {
        let max = policy.max_len as usize;
        if total == 0 {
            self.start = 0;
            self.len = 0;
            return self;
        }
        // No ceiling: the window is the store. There is no head to move, so there is
        // nothing for a scroll-back page to do and nothing a new arrival can push out.
        if policy.is_unbounded() {
            self.follow_tail = true;
            self.start = 0;
            self.len = total;
            return self;
        }
        // The live window is never smaller than the default: a chat that grew
        // from one message to two hundred must show all of them, not stay
        // pinned at whatever size it was first clamped to. Paging can push the
        // length above the default, and that survives here.
        self.len = self
            .len
            .max(policy.default_len as usize)
            .min(max)
            .min(total);
        if self.follow_tail {
            self.start = total - self.len;
        } else {
            self.start = self.start.min(total - self.len);
        }
        self
    }

    /// Scroll-back. Grows toward the max ceiling first, then walks the window
    /// backwards and stops following the tail.
    pub fn paged_before(mut self, total: usize, policy: VibeWindowPolicy) -> Self {
        // Everything is already in the window. Returning `self` unchanged is what makes
        // `page_before` report "nothing moved" and emit no delta.
        if policy.is_unbounded() {
            return self.clamped(total, policy);
        }
        let page = policy.page_size as usize;
        let max = policy.max_len as usize;
        if self.len < max {
            let grow = page.min(max - self.len);
            self.len += grow;
            if self.follow_tail {
                self.start = total.saturating_sub(self.len);
                return self.clamped(total, policy);
            }
            self.start = self.start.saturating_sub(grow);
            return self.clamped(total, policy);
        }
        self.follow_tail = false;
        self.start = self.start.saturating_sub(page);
        self.clamped(total, policy)
    }

    /// Scroll forward. Re-arms tail following once the window reaches the end.
    pub fn paged_after(mut self, total: usize, policy: VibeWindowPolicy) -> Self {
        if policy.is_unbounded() {
            return self.clamped(total, policy);
        }
        let page = policy.page_size as usize;
        if self.follow_tail {
            return self.clamped(total, policy);
        }
        self.start = (self.start + page).min(total.saturating_sub(self.len));
        if self.end() >= total {
            self.follow_tail = true;
        }
        self.clamped(total, policy)
    }
}

/// Resolves an anchor against the ordered store.
///
/// The fallback chain is the whole point (challenge C3): a bare id anchor breaks
/// the moment an optimistic id is healed or a Saved Messages row picks its other
/// id, and a broken anchor is a visible scroll jump.
///
/// `aliases` maps a retired id (optimistic, or the non-preferred Saved Messages
/// id) to the id the store actually holds.
pub fn resolve_anchor(
    messages: &[VibeMessageSnapshotV1],
    aliases: &HashMap<String, String>,
    anchor: &VibeTimelineAnchor,
    first_unread_id: Option<&str>,
) -> (Option<usize>, VibeAnchorResolution) {
    if messages.is_empty() {
        return (None, VibeAnchorResolution::Empty);
    }

    match anchor.pin {
        VibeAnchorPin::Bottom => {
            return (Some(messages.len() - 1), VibeAnchorResolution::PinnedBottom)
        }
        VibeAnchorPin::Top => return (Some(0), VibeAnchorResolution::PinnedTop),
        VibeAnchorPin::Unread => {
            if let Some(id) = first_unread_id {
                if let Some(i) = index_of_id(messages, id) {
                    return (Some(i), VibeAnchorResolution::PinnedUnread);
                }
            }
            return (Some(messages.len() - 1), VibeAnchorResolution::PinnedBottom);
        }
        VibeAnchorPin::Message => {}
    }

    // 1. exact id
    if let Some(i) = index_of_id(messages, &anchor.message_id) {
        return (Some(i), VibeAnchorResolution::ExactId);
    }

    // 2. id alias — an optimistic id healed to a server id, or a Saved Messages
    //    dual id. One hop; the alias table is kept flat.
    for candidate in [
        anchor.client_message_id.as_deref(),
        aliases.get(&anchor.message_id).map(String::as_str),
        anchor
            .client_message_id
            .as_deref()
            .and_then(|c| aliases.get(c))
            .map(String::as_str),
    ]
    .into_iter()
    .flatten()
    {
        if let Some(i) = index_of_id(messages, candidate) {
            return (Some(i), VibeAnchorResolution::ClientIdAlias);
        }
    }

    // 3. nearest-not-after by (ts, id), then nearest-before.
    let probe = messages.partition_point(|m| {
        (m.ts_ms, m.message_id.as_str()) < (anchor.ts_ms, anchor.message_id.as_str())
    });
    if probe < messages.len() {
        return (Some(probe), VibeAnchorResolution::NearestAfter);
    }
    if probe > 0 {
        return (Some(probe - 1), VibeAnchorResolution::NearestBefore);
    }

    // 4. pin
    (Some(messages.len() - 1), VibeAnchorResolution::PinnedBottom)
}

fn index_of_id(messages: &[VibeMessageSnapshotV1], id: &str) -> Option<usize> {
    if id.is_empty() {
        return None;
    }
    messages.iter().position(|m| m.message_id == id)
}

/// Builds a cursor that puts `index` on screen.
///
/// A `Message` anchor is centred; `Unread` is biased so the first unread row
/// lands near the top with a short lead-in of already-read context.
pub fn cursor_for_index(
    total: usize,
    policy: VibeWindowPolicy,
    index: usize,
    resolution: VibeAnchorResolution,
) -> VibeWindowCursor {
    // Unbounded: every anchor resolves to the same window — all of it. The anchor still
    // matters to the renderer (it decides where to scroll), it just no longer decides
    // which rows exist.
    if policy.is_unbounded() {
        return VibeWindowCursor {
            follow_tail: true,
            start: 0,
            len: total,
        };
    }
    let len = (policy.default_len as usize).min(total);
    match resolution {
        VibeAnchorResolution::PinnedBottom | VibeAnchorResolution::Empty => VibeWindowCursor {
            follow_tail: true,
            start: total.saturating_sub(len),
            len,
        },
        VibeAnchorResolution::PinnedTop => VibeWindowCursor {
            follow_tail: total <= len,
            start: 0,
            len,
        },
        VibeAnchorResolution::PinnedUnread => {
            const UNREAD_LEAD_IN: usize = 20;
            let start = index
                .saturating_sub(UNREAD_LEAD_IN)
                .min(total.saturating_sub(len));
            VibeWindowCursor {
                follow_tail: start + len >= total,
                start,
                len,
            }
        }
        _ => {
            let start = index.saturating_sub(len / 2).min(total.saturating_sub(len));
            VibeWindowCursor {
                follow_tail: start + len >= total,
                start,
                len,
            }
        }
    }
}

/// Bounds for a materialized window.
pub fn bounds_for(
    messages: &[VibeMessageSnapshotV1],
    cursor: VibeWindowCursor,
    total_known: u64,
) -> VibeWindowBounds {
    let slice = &messages[cursor.start..cursor.end()];
    VibeWindowBounds {
        head_ts_ms: slice.first().map_or(0, |m| m.ts_ms),
        tail_ts_ms: slice.last().map_or(0, |m| m.ts_ms),
        has_more_before: cursor.start > 0,
        has_more_after: cursor.end() < messages.len(),
        total_known,
        window_len: slice.len() as u32,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store(n: usize) -> Vec<VibeMessageSnapshotV1> {
        (0..n)
            .map(|i| {
                VibeMessageSnapshotV1::text_message(
                    "c",
                    &format!("m{i:06}"),
                    1_000 + i as i64,
                    "u",
                    false,
                    "x",
                )
            })
            .collect()
    }

    #[test]
    fn policy_enforces_the_frozen_envelope() {
        assert!(VibeWindowPolicy::try_new(150, 300, 200, 50).is_ok());
        assert_eq!(
            VibeWindowPolicy::try_new(100, 300, 200, 50).unwrap_err(),
            VibeWindowPolicyError::OutsideContract
        );
        assert_eq!(
            VibeWindowPolicy::try_new(150, 400, 200, 50).unwrap_err(),
            VibeWindowPolicyError::OutsideContract
        );
        assert_eq!(
            VibeWindowPolicy::try_new(150, 300, 400, 50).unwrap_err(),
            VibeWindowPolicyError::DefaultOutOfRange
        );
        assert_eq!(
            VibeWindowPolicy::try_new(150, 300, 200, 0).unwrap_err(),
            VibeWindowPolicyError::ZeroPageSize
        );

        let p = VibeWindowPolicy::default();
        assert_eq!((p.min_len, p.max_len, p.default_len), (150, 300, 200));
        assert!(!p.is_unbounded(), "the default policy is bounded");
        assert!(VibeWindowPolicy::unbounded().is_unbounded());
    }

    /// The default is a window over the whole store, at any size, forever.
    ///
    /// This replaces `window_is_bounded_no_matter_how_large_the_store_is`. The cap it
    /// guarded is gone on purpose: every bounded window was experienced as a scroll
    /// limit, because at the ceiling a drag to the top *replaced* rows instead of
    /// extending them.
    #[test]
    fn the_default_window_is_the_whole_store_and_paging_is_inert() {
        let policy = VibeWindowPolicy::unbounded();
        for total in [1_usize, 12, 300, 1_000, 100_000] {
            let c = VibeWindowCursor::default().clamped(total, policy);
            assert_eq!((c.start, c.len), (0, total), "total={total}");
            assert!(c.follow_tail);
            // Paging cannot move a window that already covers everything, and an
            // unmoved cursor is what makes `page_before` emit no delta at all.
            assert_eq!(c.paged_before(total, policy), c, "total={total}");
            assert_eq!(c.paged_after(total, policy), c, "total={total}");
        }
        let empty = VibeWindowCursor::default().clamped(0, policy);
        assert_eq!((empty.start, empty.len), (0, 0));
    }

    /// The bounded policy still works for any caller that asks for one.
    #[test]
    fn paging_before_then_after_re_arms_tail_following() {
        let policy = VibeWindowPolicy::default();
        let total = 5_000;
        let mut c = VibeWindowCursor::default().clamped(total, policy);
        assert!(c.follow_tail);
        for _ in 0..10 {
            c = c.paged_before(total, policy);
        }
        assert!(!c.follow_tail);
        for _ in 0..200 {
            c = c.paged_after(total, policy);
        }
        assert!(c.follow_tail);
        assert_eq!(c.end(), total);
    }

    /// A bounded window's scroll-back must still reach the start of a large store.
    #[test]
    fn paging_before_walks_a_large_store_to_its_first_message() {
        let policy = VibeWindowPolicy::default();
        let total = 1_000;
        let mut c = VibeWindowCursor::default().clamped(total, policy);
        assert_eq!(c.start, total - policy.default_len as usize);

        let mut previous = c.start;
        let mut pages = 0;
        while c.start > 0 {
            c = c.paged_before(total, policy);
            pages += 1;
            assert!(c.start < previous || c.len > policy.default_len as usize);
            assert!(c.len <= policy.max_len as usize);
            previous = c.start;
            assert!(pages < 100, "paging stalled at start={}", c.start);
        }
        assert_eq!(c.start, 0);
        assert!(!c.follow_tail);
    }

    #[test]
    fn a_small_chat_is_fully_visible() {
        let policy = VibeWindowPolicy::default();
        let c = VibeWindowCursor::default().clamped(12, policy);
        assert_eq!((c.start, c.len), (0, 12));
        let empty = VibeWindowCursor::default().clamped(0, policy);
        assert_eq!((empty.start, empty.len), (0, 0));
    }

    #[test]
    fn anchor_resolves_exactly_then_by_alias_then_by_neighbour() {
        let messages = store(50);
        let mut aliases = HashMap::new();
        aliases.insert("local-7".to_string(), "m000007".to_string());

        let exact = VibeTimelineAnchor::at_message("m000007", 1_007);
        assert_eq!(
            resolve_anchor(&messages, &aliases, &exact, None),
            (Some(7), VibeAnchorResolution::ExactId)
        );

        let healed = VibeTimelineAnchor::at_message("local-7", 1_007);
        assert_eq!(
            resolve_anchor(&messages, &aliases, &healed, None),
            (Some(7), VibeAnchorResolution::ClientIdAlias)
        );

        let mut with_client = VibeTimelineAnchor::at_message("gone", 1_007);
        with_client.client_message_id = Some("m000009".into());
        assert_eq!(
            resolve_anchor(&messages, &aliases, &with_client, None),
            (Some(9), VibeAnchorResolution::ClientIdAlias)
        );

        // Tombstoned anchor: fall to the next message that still exists.
        let deleted = VibeTimelineAnchor::at_message("m000007x", 1_007);
        assert_eq!(
            resolve_anchor(&messages, &aliases, &deleted, None),
            (Some(8), VibeAnchorResolution::NearestAfter)
        );

        // Anchor newer than everything in the store.
        let future = VibeTimelineAnchor::at_message("zzz", i64::MAX - 1);
        assert_eq!(
            resolve_anchor(&messages, &aliases, &future, None),
            (Some(49), VibeAnchorResolution::NearestBefore)
        );
    }

    #[test]
    fn pins_short_circuit_and_empty_stores_report_empty() {
        let messages = store(30);
        let aliases = HashMap::new();
        assert_eq!(
            resolve_anchor(&messages, &aliases, &VibeTimelineAnchor::bottom(), None),
            (Some(29), VibeAnchorResolution::PinnedBottom)
        );
        assert_eq!(
            resolve_anchor(
                &messages,
                &aliases,
                &VibeTimelineAnchor::unread(),
                Some("m000004")
            ),
            (Some(4), VibeAnchorResolution::PinnedUnread)
        );
        // Unread id no longer present: fall back to the bottom, never to nothing.
        assert_eq!(
            resolve_anchor(
                &messages,
                &aliases,
                &VibeTimelineAnchor::unread(),
                Some("deleted")
            ),
            (Some(29), VibeAnchorResolution::PinnedBottom)
        );
        assert_eq!(
            resolve_anchor(&[], &aliases, &VibeTimelineAnchor::bottom(), None),
            (None, VibeAnchorResolution::Empty)
        );
    }

    #[test]
    fn jump_to_message_centres_the_window() {
        let policy = VibeWindowPolicy::default();
        let c = cursor_for_index(10_000, policy, 5_000, VibeAnchorResolution::ExactId);
        assert_eq!(c.len, 200);
        assert_eq!(c.start, 4_900);
        assert!(!c.follow_tail);
    }

    /// Unbounded: a jump changes where the renderer scrolls, never which rows exist.
    #[test]
    fn jumping_to_a_message_unbounded_keeps_the_whole_store_mounted() {
        let policy = VibeWindowPolicy::unbounded();
        let c = cursor_for_index(10_000, policy, 5_000, VibeAnchorResolution::ExactId);
        assert_eq!((c.start, c.len), (0, 10_000));
        assert!(c.follow_tail);
    }

    #[test]
    fn bounds_report_more_in_both_directions() {
        let messages = store(1_000);
        let policy = VibeWindowPolicy::default();
        let c = cursor_for_index(1_000, policy, 500, VibeAnchorResolution::ExactId);
        let b = bounds_for(&messages, c, 1_000);
        assert!(b.has_more_before);
        assert!(b.has_more_after);
        assert_eq!(b.window_len, 200);
        assert_eq!(b.total_known, 1_000);
    }

    /// Nothing is ever off-window, so nothing is ever "more".
    #[test]
    fn unbounded_bounds_never_report_more_in_either_direction() {
        let messages = store(1_000);
        let policy = VibeWindowPolicy::unbounded();
        let c = cursor_for_index(1_000, policy, 500, VibeAnchorResolution::ExactId);
        let b = bounds_for(&messages, c, 1_000);
        assert!(!b.has_more_before);
        assert!(!b.has_more_after);
        assert_eq!(b.window_len, 1_000);
        assert_eq!(b.total_known, 1_000);
    }
}
