//! Duplicate suppression.
//!
//! This is a port of `ChatEngine.mergedChatRowsLocked`, which is ~210 lines of
//! ordering-sensitive heuristics with no test coverage in Swift. Each heuristic
//! becomes a named pure predicate here, with the shipped constant carried over
//! verbatim rather than re-derived — every one of these numbers was tuned
//! against a real incident.
//!
//! | Predicate | Shipped constant |
//! |---|---|
//! | [`dedup_mirrored_prompt`] | 48 h |
//! | [`dedup_persisted_agent_twin`] | 5 min |
//! | [`drop_empty_agent_shell`] | — |
//! | [`drop_stale_stream_row`] | — |
//! | [`terminalize_stale_streaming`] | 3 min history-only, 60 min live |

use std::collections::HashSet;

use crate::types::{VibeMessageFlags, VibeMessageSnapshotV1};

/// How far apart an own sent row and its transcript mirror may sit and still be
/// the same prompt. Wide on purpose: transcript timestamps come from the CLI's
/// clock and a history re-ingest can land much later than the original send.
pub const BRIDGE_MIRROR_DEDUP_WINDOW_MS: i64 = 48 * 3600 * 1000;

/// How far apart a persisted agent reply and its transcript mirror may sit.
pub const PERSISTED_AGENT_TWIN_WINDOW_MS: i64 = 5 * 60 * 1000;

/// A row present only in history settles fast: no live row is feeding it.
pub const STALE_STREAMING_HISTORY_ONLY_MS: i64 = 3 * 60 * 1000;

/// A row also present in the live store gets a long grace. A genuinely live turn
/// keeps a fast-refreshing live row; nothing streams for an hour.
pub const STALE_STREAMING_LIVE_MS: i64 = 60 * 60 * 1000;

/// Transient id prefixes. These ids are **never persisted**: they belong to a
/// bridge session, not to the durable transcript.
pub const TRANSIENT_ID_PREFIXES: [&str; 3] = ["stream-", "lan-", "bridge-"];

/// True when an id belongs to a bridge/stream session rather than the server.
pub fn is_transient_id(message_id: &str) -> bool {
    TRANSIENT_ID_PREFIXES
        .iter()
        .any(|p| message_id.starts_with(p))
}

/// True for the bridge transcript mirror specifically.
pub fn is_bridge_mirror_id(message_id: &str) -> bool {
    message_id.starts_with("bridge-")
}

/// True for a live stream row.
pub fn is_stream_id(message_id: &str) -> bool {
    message_id.starts_with("stream-")
}

/// True for the synthetic host row a running team turn mirrors into.
pub fn is_running_mirror_id(message_id: &str) -> bool {
    message_id.contains("running-mirror")
}

/// Strips the daemon's instruction preamble from a transcript user turn.
///
/// The bridge prepends "Vibe bridge startup prepared these instruction files…
/// User task:\n<text>" to every prompt before handing it to the CLI. The CLI
/// transcript records the *full* prompt, so re-ingesting that transcript as
/// history would show the preamble in the user's own bubble.
///
/// Gated on the exact prefix so an ordinary message that happens to contain
/// "User task:" is untouched. Port of `ChatEngine.strippedBridgeInstructionPreamble`.
pub fn strip_bridge_instruction_preamble(text: &str) -> &str {
    const PREAMBLE_PREFIX: &str = "Vibe bridge startup prepared these instruction files";
    const TASK_MARKER: &str = "User task:";
    if !text.starts_with(PREAMBLE_PREFIX) {
        return text;
    }
    match text.find(TASK_MARKER) {
        Some(at) => text[at + TASK_MARKER.len()..].trim(),
        None => text,
    }
}

/// Comparable form of a mirrored prompt.
///
/// Strips **both** daemon-added preambles, in the order the shipped client
/// strips them: the instruction-files preamble first, then the attachment
/// pointer ("The user attached N image file(s)…\n\n"). Two prompts are the same
/// send when their comparable forms match.
///
/// Order matters and the attachment check runs on the *already instruction-
/// stripped* body: a prompt that carries both preambles would otherwise keep the
/// attachment pointer, fail to match its own sent row, and render as a duplicate
/// bubble. Port of `ChatEngine.bridgeMirrorComparableText`.
pub fn bridge_mirror_comparable_text(text: &str) -> &str {
    let body = strip_bridge_instruction_preamble(text);
    let body = if body.starts_with("The user attached ") {
        body.split_once("\n\n").map_or(body, |(_, rest)| rest)
    } else {
        body
    };
    body.trim()
}

/// A candidate for dedup, extracted once so the predicates are O(n) rather than
/// O(n²) over full snapshots.
struct OwnPromptRef<'a> {
    text: &'a str,
    ts_ms: i64,
}

struct AgentReplyRef<'a> {
    text: &'a str,
    provider: &'a str,
    ts_ms: i64,
}

/// Drops the bridge transcript's copy of a prompt the user already sent.
///
/// A session transcript records the user's own prompt as a user turn, and bridge
/// ingest re-emits it as a `bridge-…` row while the phone already renders the
/// real sent message under its own server id. Same text, two ids, two bubbles.
///
/// When a History session is viewed in isolation the server rows are absent from
/// the merge, so the mirrored rows survive there — as they must.
pub fn dedup_mirrored_prompt(messages: &[VibeMessageSnapshotV1]) -> HashSet<String> {
    let own_prompts: Vec<OwnPromptRef<'_>> = messages
        .iter()
        .filter(|m| {
            !is_transient_id(&m.message_id) && m.author.is_me && !m.body.text.trim().is_empty()
        })
        .map(|m| OwnPromptRef {
            text: m.body.text.trim(),
            ts_ms: m.ts_ms,
        })
        .collect();

    if own_prompts.is_empty() {
        return HashSet::new();
    }

    messages
        .iter()
        .filter(|m| is_bridge_mirror_id(&m.message_id) && m.author.is_me)
        .filter(|m| {
            let text = bridge_mirror_comparable_text(&m.body.text);
            if text.is_empty() {
                return false;
            }
            own_prompts.iter().any(|p| {
                p.text == text && p.ts_ms.abs_diff(m.ts_ms) <= BRIDGE_MIRROR_DEDUP_WINDOW_MS as u64
            })
        })
        .map(|m| m.message_id.clone())
        .collect()
}

/// Drops a bridge transcript mirror of an agent reply that was also persisted as
/// a canonical server message.
///
/// The persisted row wins: it carries delivery state and runtime metadata. Only
/// an exact-text, same-provider mirror nearby in time is suppressed, so a
/// History-only view (which has no persisted twin) is untouched.
pub fn dedup_persisted_agent_twin(messages: &[VibeMessageSnapshotV1]) -> HashSet<String> {
    let persisted: Vec<AgentReplyRef<'_>> = messages
        .iter()
        .filter(|m| !is_transient_id(&m.message_id) && m.agent.is_some())
        .filter(|m| !m.body.text.trim().is_empty())
        .map(|m| AgentReplyRef {
            text: m.body.text.trim(),
            provider: m.agent.as_ref().map_or("", |a| a.provider.as_str()),
            ts_ms: m.ts_ms,
        })
        .collect();

    if persisted.is_empty() {
        return HashSet::new();
    }

    messages
        .iter()
        .filter(|m| is_bridge_mirror_id(&m.message_id) && m.agent.is_some())
        .filter(|m| {
            let text = m.body.text.trim();
            if text.is_empty() {
                return false;
            }
            let provider = m.agent.as_ref().map_or("", |a| a.provider.as_str());
            persisted.iter().any(|p| {
                p.text == text
                    // An unknown provider on either side is not a mismatch: the
                    // persisted row sometimes lands before the provider map does.
                    && (p.provider.is_empty()
                        || provider.is_empty()
                        || p.provider.eq_ignore_ascii_case(provider))
                    && p.ts_ms.abs_diff(m.ts_ms) <= PERSISTED_AGENT_TWIN_WINDOW_MS as u64
            })
        })
        .map(|m| m.message_id.clone())
        .collect()
}

/// True when an agent row has no body and no real progress steps.
///
/// A blank agent bubble corrupts height layout and overlaps its neighbours. A
/// streaming turn whose only node is a bare `thinking` placeholder is held out
/// of the list too — the header shows "Thinking…" instead.
pub fn is_empty_agent_shell(message: &VibeMessageSnapshotV1) -> bool {
    let Some(agent) = &message.agent else {
        return false;
    };
    if !message.body.text.trim().is_empty() {
        return false;
    }
    if agent.progress.is_empty() {
        return true;
    }
    agent.progress.iter().all(|n| {
        let kind = n.kind.to_ascii_lowercase();
        let label = n.label.trim().to_ascii_lowercase();
        let is_thinking = kind == "thinking" || label == "thinking" || label == "thinking...";
        is_thinking && n.detail.as_deref().is_none_or(|d| d.trim().is_empty())
    })
}

/// Ids of every empty agent shell.
pub fn drop_empty_agent_shell(messages: &[VibeMessageSnapshotV1]) -> HashSet<String> {
    messages
        .iter()
        .filter(|m| is_empty_agent_shell(m))
        .map(|m| m.message_id.clone())
        .collect()
}

/// Drops `stream-` rows once a finished `bridge-` card owns the same turn, and
/// empty `running-mirror` hosts.
///
/// This is the classic empty "Worked" duplicate after a bridge restart, and the
/// dual-apply of the same prose (stream row + bridge card) in the logs.
pub fn drop_stale_stream_row(messages: &[VibeMessageSnapshotV1]) -> HashSet<String> {
    let has_finished_agent_card = messages.iter().any(|m| {
        is_bridge_mirror_id(&m.message_id)
            && m.agent.is_some()
            && !m.flags.contains(VibeMessageFlags::STREAMING)
    });

    messages
        .iter()
        .filter(|m| m.agent.is_some())
        .filter(|m| {
            if is_stream_id(&m.message_id) && has_finished_agent_card {
                return true;
            }
            if is_running_mirror_id(&m.message_id) && m.body.text.trim().is_empty() {
                return has_finished_agent_card || !m.flags.contains(VibeMessageFlags::STREAMING);
            }
            false
        })
        .map(|m| m.message_id.clone())
        .collect()
}

/// Coerces orphaned streaming rows to a terminal state.
///
/// A persisted agent row that still claims to be streaming but has no live row
/// feeding it and has not been touched in minutes is an orphan: its run ended
/// without a terminal frame (CLI crash, or a server redeploy reset the
/// finalizing monitor). Left alone it re-renders as a live shimmering cell on
/// every history load.
///
/// `has_live_row` decides the grace period, and `now_ms` is injected so this is
/// deterministic under replay.
pub fn terminalize_stale_streaming(
    messages: &mut [VibeMessageSnapshotV1],
    now_ms: i64,
    has_live_row: &dyn Fn(&str) -> bool,
) -> Vec<String> {
    let mut settled = Vec::new();
    for m in messages.iter_mut() {
        if !m.flags.contains(VibeMessageFlags::STREAMING) {
            continue;
        }
        if m.agent.is_none() {
            continue;
        }
        let min_stale_ms = if has_live_row(&m.message_id) {
            STALE_STREAMING_LIVE_MS
        } else {
            STALE_STREAMING_HISTORY_ONLY_MS
        };
        if now_ms.saturating_sub(m.ts_ms) < min_stale_ms {
            continue;
        }
        m.flags.remove(VibeMessageFlags::STREAMING);
        if let Some(agent) = m.agent.as_mut() {
            agent.is_streaming = false;
        }
        m.rehash();
        settled.push(m.message_id.clone());
    }
    settled
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{VibeAgentProgressNode, VibeAgentRef};

    fn text_msg(id: &str, ts: i64, is_me: bool, text: &str) -> VibeMessageSnapshotV1 {
        VibeMessageSnapshotV1::text_message("chat", id, ts, "u1", is_me, text)
    }

    /// The exact preamble the daemon prepends, as the shipped client matches it.
    const INSTRUCTION_PREAMBLE: &str =
        "Vibe bridge startup prepared these instruction files for you.\nUser task:\n";

    #[test]
    fn instruction_preamble_is_stripped() {
        let raw = format!("{INSTRUCTION_PREAMBLE}fix the login bug");
        assert_eq!(bridge_mirror_comparable_text(&raw), "fix the login bug");
    }

    #[test]
    fn both_preambles_strip_in_the_shipped_order() {
        // The case the single-strip implementation got wrong: a prompt carrying
        // an attachment *and* the instruction block kept the attachment pointer
        // and therefore never matched its own sent row.
        let raw = format!(
            "{INSTRUCTION_PREAMBLE}The user attached 2 image file(s) to this message.\n\nlook at these"
        );
        assert_eq!(bridge_mirror_comparable_text(&raw), "look at these");
    }

    #[test]
    fn attachment_preamble_alone_still_strips() {
        let raw = "The user attached 1 image file(s) to this message.\n\nwhat is this";
        assert_eq!(bridge_mirror_comparable_text(raw), "what is this");
    }

    #[test]
    fn ordinary_text_mentioning_the_marker_is_untouched() {
        // Gated on the exact prefix, so a normal message that happens to say
        // "User task:" keeps every character.
        let raw = "here is my User task: ship it";
        assert_eq!(bridge_mirror_comparable_text(raw), raw);
    }

    #[test]
    fn preamble_prefix_without_the_marker_is_left_alone() {
        let raw = "Vibe bridge startup prepared these instruction files and stopped";
        assert_eq!(bridge_mirror_comparable_text(raw), raw);
    }

    #[test]
    fn a_mirror_carrying_both_preambles_dedups_against_the_real_send() {
        // End-to-end: the parity bug as it would have reached a user — two
        // bubbles for one prompt.
        let sent = text_msg("srv-1", 1_000, true, "look at these");
        let mirror = text_msg(
            "bridge-1",
            2_000,
            true,
            &format!(
                "{INSTRUCTION_PREAMBLE}The user attached 2 image file(s) to this message.\n\nlook at these"
            ),
        );
        let dropped = dedup_mirrored_prompt(&[sent, mirror]);
        assert!(dropped.contains("bridge-1"));
    }

    fn agent_msg(
        id: &str,
        ts: i64,
        text: &str,
        provider: &str,
        streaming: bool,
        nodes: Vec<VibeAgentProgressNode>,
    ) -> VibeMessageSnapshotV1 {
        let mut m = text_msg(id, ts, false, text);
        m.agent = Some(VibeAgentRef {
            provider: provider.to_string(),
            task_id: None,
            session_id: None,
            sealed: None,
            progress: nodes,
            is_streaming: streaming,
            elapsed_ms: None,
        });
        m.flags.set(VibeMessageFlags::STREAMING, streaming);
        m.rehash();
        m
    }

    fn node(kind: &str, label: &str, detail: Option<&str>) -> VibeAgentProgressNode {
        VibeAgentProgressNode {
            id: format!("{kind}-{label}"),
            kind: kind.into(),
            label: label.into(),
            detail: detail.map(str::to_string),
            is_terminal: false,
        }
    }

    #[test]
    fn transient_ids_are_classified() {
        assert!(is_transient_id("bridge-abc"));
        assert!(is_transient_id("stream-abc"));
        assert!(is_transient_id("lan-abc"));
        assert!(!is_transient_id("7f0e-uuid"));
    }

    #[test]
    fn mirrored_prompt_is_dropped_and_the_real_send_is_kept() {
        let rows = vec![
            text_msg("uuid-1", 1000, true, "Continue"),
            text_msg("bridge-9", 1500, true, "Continue"),
        ];
        let dropped = dedup_mirrored_prompt(&rows);
        assert_eq!(dropped.len(), 1);
        assert!(dropped.contains("bridge-9"));
    }

    #[test]
    fn mirrored_prompt_survives_when_viewed_in_isolation() {
        // History-only session view: no server row in the merge.
        let rows = vec![text_msg("bridge-9", 1500, true, "Continue")];
        assert!(dedup_mirrored_prompt(&rows).is_empty());
    }

    #[test]
    fn attachment_preamble_is_stripped_before_comparing() {
        let raw = "The user attached 1 image\n\nDescribe this";
        assert_eq!(bridge_mirror_comparable_text(raw), "Describe this");
        let rows = vec![
            text_msg("uuid-1", 1000, true, "Describe this"),
            text_msg("bridge-9", 1500, true, raw),
        ];
        assert!(dedup_mirrored_prompt(&rows).contains("bridge-9"));
    }

    #[test]
    fn mirror_outside_the_48h_window_is_kept() {
        let rows = vec![
            text_msg("uuid-1", 0, true, "Continue"),
            text_msg(
                "bridge-9",
                BRIDGE_MIRROR_DEDUP_WINDOW_MS + 1,
                true,
                "Continue",
            ),
        ];
        assert!(dedup_mirrored_prompt(&rows).is_empty());
    }

    #[test]
    fn persisted_agent_twin_drops_only_the_bridge_copy() {
        let rows = vec![
            agent_msg("uuid-2", 1000, "Done.", "claude", false, vec![]),
            agent_msg("bridge-2", 1100, "Done.", "claude", false, vec![]),
        ];
        let dropped = dedup_persisted_agent_twin(&rows);
        assert_eq!(dropped.len(), 1);
        assert!(dropped.contains("bridge-2"));
    }

    #[test]
    fn different_provider_is_not_a_twin() {
        let rows = vec![
            agent_msg("uuid-2", 1000, "Done.", "claude", false, vec![]),
            agent_msg("bridge-2", 1100, "Done.", "codex", false, vec![]),
        ];
        assert!(dedup_persisted_agent_twin(&rows).is_empty());
    }

    #[test]
    fn empty_agent_shells_and_placeholder_thinking_are_dropped() {
        let empty = agent_msg("bridge-1", 1, "", "claude", true, vec![]);
        assert!(is_empty_agent_shell(&empty));

        let placeholder = agent_msg(
            "bridge-2",
            1,
            "",
            "claude",
            true,
            vec![node("thinking", "Thinking", None)],
        );
        assert!(is_empty_agent_shell(&placeholder));

        let real = agent_msg(
            "bridge-3",
            1,
            "",
            "claude",
            true,
            vec![node("tool", "Read", Some("lib.rs"))],
        );
        assert!(!is_empty_agent_shell(&real));

        let with_body = agent_msg("bridge-4", 1, "hi", "claude", true, vec![]);
        assert!(!is_empty_agent_shell(&with_body));
    }

    #[test]
    fn stream_row_is_dropped_once_a_finished_card_exists() {
        let rows = vec![
            agent_msg("stream-1", 1000, "partial", "claude", true, vec![]),
            agent_msg("bridge-1", 1100, "final", "claude", false, vec![]),
        ];
        let dropped = drop_stale_stream_row(&rows);
        assert_eq!(dropped.len(), 1);
        assert!(dropped.contains("stream-1"));
    }

    #[test]
    fn stream_row_survives_while_the_card_is_still_streaming() {
        let rows = vec![
            agent_msg("stream-1", 1000, "partial", "claude", true, vec![]),
            agent_msg("bridge-1", 1100, "still going", "claude", true, vec![]),
        ];
        assert!(drop_stale_stream_row(&rows).is_empty());
    }

    #[test]
    fn orphaned_streaming_rows_settle_on_the_right_grace() {
        let mut rows = vec![
            agent_msg("bridge-1", 0, "half", "claude", true, vec![]),
            agent_msg("bridge-2", 0, "half", "claude", true, vec![]),
        ];
        let live = |id: &str| id == "bridge-2";
        let settled =
            terminalize_stale_streaming(&mut rows, STALE_STREAMING_HISTORY_ONLY_MS, &live);
        assert_eq!(settled, vec!["bridge-1".to_string()]);
        assert!(!rows[0].flags.contains(VibeMessageFlags::STREAMING));
        assert!(rows[1].flags.contains(VibeMessageFlags::STREAMING));

        let settled = terminalize_stale_streaming(&mut rows, STALE_STREAMING_LIVE_MS, &live);
        assert_eq!(settled, vec!["bridge-2".to_string()]);
    }

    #[test]
    fn a_fresh_streaming_row_is_never_terminalized() {
        let mut rows = vec![agent_msg("bridge-1", 1_000, "half", "claude", true, vec![])];
        let live = |_: &str| false;
        assert!(terminalize_stale_streaming(&mut rows, 1_100, &live).is_empty());
        assert!(rows[0].flags.contains(VibeMessageFlags::STREAMING));
    }
}
