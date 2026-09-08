//! Deterministic synthetic fixtures.
//!
//! **Every fixture in this crate is synthetic.** No production frame, no real
//! message body, no real key, and no captured payload is committed to this
//! repository. A redacted production corpus would make the fuzz seeds better and
//! is a separate decision with its own privacy review; until that decision is
//! made, this module is the corpus.
//!
//! Determinism is the point: [`VibeFixtureRng`] is a seeded SplitMix64, the
//! clock is a parameter, and no fixture reads the system time, the filesystem, or
//! the network. Two runs of the same seed produce byte-identical events.

use crate::types::{VibeCoreEventV1, VibeEventBody, VibeEventSource};

/// SplitMix64. Small, fast, and reproducible across platforms and Rust versions
/// — which a `HashMap`-derived or time-derived source would not be.
#[derive(Clone, Copy, Debug)]
pub struct VibeFixtureRng {
    state: u64,
}

impl VibeFixtureRng {
    pub fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    pub fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform in `0..n`.
    pub fn below(&mut self, n: u64) -> u64 {
        if n == 0 {
            0
        } else {
            self.next_u64() % n
        }
    }

    pub fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        &items[self.below(items.len() as u64) as usize]
    }
}

/// Shape of a synthetic message.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VibeFixtureKind {
    Text,
    Image,
    Voice,
    AgentTurn,
    Service,
}

/// Builds one raw server frame as JSON bytes.
///
/// The frame goes through the real [`crate::canonical`] path, so a fixture that
/// exercises a field alias is exercising the production resolution order.
pub fn frame(
    chat_id: &str,
    message_id: &str,
    ts_ms: i64,
    sender_id: &str,
    kind: VibeFixtureKind,
    text: &str,
) -> Vec<u8> {
    let escaped = escape_json(text);
    let body = match kind {
        VibeFixtureKind::Text => format!(
            r#"{{"id":"{message_id}","chat_id":"{chat_id}","sender_id":"{sender_id}","timestamp":{ts_ms},"encrypted_content":"{}"}}"#,
            escape_json(&format!(r#"{{"text":"{escaped}"}}"#))
        ),
        VibeFixtureKind::Image => {
            let payload = format!(
                r#"{{"text":"","caption":"{escaped}","mediaUrl":"https://cdn.vibegram.io/m/{message_id}.jpg","mediaKey":"k-{message_id}","mimeType":"image/jpeg","width":1600,"height":900}}"#
            );
            format!(
                r#"{{"id":"{message_id}","chat_id":"{chat_id}","sender_id":"{sender_id}","timestamp":{ts_ms},"type":"image","encrypted_content":"{}"}}"#,
                escape_json(&payload)
            )
        }
        VibeFixtureKind::Voice => {
            let payload = format!(
                r#"{{"text":"","mediaUrl":"https://cdn.vibegram.io/m/{message_id}.m4a","mediaKey":"k-{message_id}","mimeType":"audio/m4a","duration":7.5,"waveform":[10,80,200,40,90]}}"#
            );
            format!(
                r#"{{"id":"{message_id}","chat_id":"{chat_id}","sender_id":"{sender_id}","timestamp":{ts_ms},"type":"voice","encrypted_content":"{}"}}"#,
                escape_json(&payload)
            )
        }
        VibeFixtureKind::AgentTurn => format!(
            r#"{{"id":"{message_id}","chat_id":"{chat_id}","sender_id":"{sender_id}","timestamp":{ts_ms},"isAgentMessage":true,"agentUserId":"CLAUDE","isStreaming":false,"plainContent":"{escaped}","progressNodes":[{{"id":"n1","kind":"tool","label":"Read","detail":"lib.rs"}}]}}"#
        ),
        VibeFixtureKind::Service => format!(
            r#"{{"id":"{message_id}","chat_id":"{chat_id}","sender_id":"{sender_id}","timestamp":{ts_ms},"serviceNode":{{"kind":"membership","title":"{escaped}","chips":[{{"id":"accept","label":"Accept","style":"primary"}}]}}}}"#
        ),
    };
    body.into_bytes()
}

/// A deterministic conversation: `count` messages alternating between two
/// participants, with a fixed distribution of media and agent turns.
pub fn conversation(
    chat_id: &str,
    seed: u64,
    count: usize,
    start_ts_ms: i64,
) -> Vec<VibeCoreEventV1> {
    let mut rng = VibeFixtureRng::new(seed);
    let mut out = Vec::with_capacity(count);
    for i in 0..count {
        let ts = start_ts_ms + i as i64 * 1_000;
        let sender = if i % 2 == 0 { "me" } else { "peer" };
        let kind = match rng.below(100) {
            0..=79 => VibeFixtureKind::Text,
            80..=89 => VibeFixtureKind::Image,
            90..=94 => VibeFixtureKind::Voice,
            95..=98 => VibeFixtureKind::AgentTurn,
            _ => VibeFixtureKind::Service,
        };
        let id = format!("m{i:08}");
        let json = frame(
            chat_id,
            &id,
            ts,
            sender,
            kind,
            &format!("synthetic body {i}"),
        );
        out.push(VibeCoreEventV1::new(
            chat_id,
            ts,
            VibeEventSource::ChatTopic,
            VibeEventBody::RawFrame { json },
        ));
    }
    out
}

/// A history page: one event carrying `count` frames.
pub fn history_page(
    chat_id: &str,
    seed: u64,
    count: usize,
    start_ts_ms: i64,
    id_offset: usize,
) -> VibeCoreEventV1 {
    let mut rng = VibeFixtureRng::new(seed);
    let mut frames = Vec::with_capacity(count);
    for i in 0..count {
        let ts = start_ts_ms + i as i64 * 1_000;
        let sender = if i % 2 == 0 { "me" } else { "peer" };
        let kind = *rng.pick(&[
            VibeFixtureKind::Text,
            VibeFixtureKind::Text,
            VibeFixtureKind::Text,
            VibeFixtureKind::Image,
        ]);
        let id = format!("m{:08}", i + id_offset);
        let json = frame(chat_id, &id, ts, sender, kind, &format!("page body {i}"));
        frames.push(String::from_utf8(json).expect("fixture frames are utf-8"));
    }
    let array = format!("[{}]", frames.join(","));
    VibeCoreEventV1::new(
        chat_id,
        start_ts_ms,
        VibeEventSource::HistoryPage,
        VibeEventBody::RawFrames {
            json_array: array.into_bytes(),
        },
    )
}

/// Malformed `encrypted_content` corpus.
///
/// Every entry must be *rejected without panicking* and without producing a
/// message that renders as though it decrypted. These are the seeds a
/// `cargo-fuzz` target starts from; the crate is fuzz-ready in the sense that
/// [`crate::envelope::parse_hybrid`] and
/// [`crate::canonical::canonicalize_frame`] are pure, allocation-bounded
/// functions over `&[u8]` with no global state.
pub fn malformed_envelope_corpus() -> Vec<String> {
    use base64::engine::general_purpose::STANDARD as B64;
    use base64::Engine as _;

    let iv = B64.encode([1u8; 12]);
    let short_iv = B64.encode([1u8; 8]);
    let c = B64.encode([2u8; 48]);
    let short_c = B64.encode([2u8; 4]);
    let k = B64.encode([3u8; 256]);

    vec![
        String::new(),
        " ".to_string(),
        "{".to_string(),
        "{}".to_string(),
        "[]".to_string(),
        "null".to_string(),
        "not json at all".to_string(),
        r#"{"iv":1,"c":2,"k":3}"#.to_string(),
        r#"{"iv":"!!!","c":"!!!","k":"!!!"}"#.to_string(),
        format!(r#"{{"iv":"{short_iv}","c":"{c}","k":"{k}"}}"#),
        format!(r#"{{"iv":"{iv}","c":"{short_c}","k":"{k}"}}"#),
        format!(r#"{{"iv":"{iv}","c":"{c}","k":""}}"#),
        format!(r#"{{"iv":"{iv}","c":"{c}"}}"#),
        format!(r#"{{"v":0,"iv":"{iv}","c":"{c}","k":"{k}"}}"#),
        format!(r#"{{"v":2,"iv":"{iv}","c":"{c}","k":"{k}"}}"#),
        format!(r#"{{"v":"1","iv":"{iv}","c":"{c}","k":"{k}"}}"#),
        format!(r#"{{"v":1,"iv":"{iv}","c":"{c}","k":"{k}","s":42}}"#),
        format!(r#"{{"v":1,"iv":"{iv}","c":"{c}","k":"{k}","g":"!!"}}"#),
        // Deeply nested JSON: must not recurse without bound.
        format!("{}{}", "[".repeat(200), "]".repeat(200)),
        // Valid envelope shape wrapping a payload that is not JSON once opened.
        format!(r#"{{"v":1,"iv":"{iv}","c":"{c}","k":"{k}"}}"#),
        // Agent blobs with wrong component lengths.
        "arte1.".to_string(),
        "arte1.a.b".to_string(),
        format!("arte1.{}.{}.{}", iv, c, short_iv),
        format!("arte1.{iv}.{c}.{c}.{c}"),
    ]
}

/// Malformed *frame* corpus (the outer object, not the envelope).
pub fn malformed_frame_corpus() -> Vec<Vec<u8>> {
    vec![
        b"".to_vec(),
        b"null".to_vec(),
        b"[]".to_vec(),
        b"{}".to_vec(),
        br#"{"id":""}"#.to_vec(),
        br#"{"id":null}"#.to_vec(),
        br#"{"id":123,"timestamp":"not a number"}"#.to_vec(),
        br#"{"id":"a","timestamp":"2026-99-99T99:99:99Z"}"#.to_vec(),
        br#"{"id":"a","encrypted_content":123}"#.to_vec(),
        br#"{"id":"a","progressNodes":"not an array"}"#.to_vec(),
        br#"{"id":"a","serviceNode":"not an object"}"#.to_vec(),
        br#"{"id":"a","metadata":[]}"#.to_vec(),
        br#"{"id":"a","waveform":["x",null,{}]}"#.to_vec(),
        br#"{"id":"a","width":-1,"height":-1,"mediaUrl":"https://x/y"}"#.to_vec(),
        b"{\"id\":\"a\",\"timestamp\":9223372036854775807}".to_vec(),
        b"{\"id\":\"a\",\"timestamp\":-9223372036854775808}".to_vec(),
    ]
}

/// A duplicate storm: the same logical message delivered `copies` times from
/// mixed sources, plus its bridge mirror.
pub fn duplicate_storm(chat_id: &str, copies: usize, ts_ms: i64) -> Vec<VibeCoreEventV1> {
    let mut out = Vec::with_capacity(copies * 2);
    for i in 0..copies {
        let source = match i % 4 {
            0 => VibeEventSource::ChatTopic,
            1 => VibeEventSource::UserTopic,
            2 => VibeEventSource::HistoryPage,
            _ => VibeEventSource::StoreRestore,
        };
        out.push(VibeCoreEventV1::new(
            chat_id,
            ts_ms,
            source,
            VibeEventBody::RawFrame {
                json: frame(
                    chat_id,
                    "server-1",
                    ts_ms,
                    "me",
                    VibeFixtureKind::Text,
                    "Continue",
                ),
            },
        ));
    }
    out.push(VibeCoreEventV1::new(
        chat_id,
        ts_ms + 500,
        VibeEventSource::BridgeMirror,
        VibeEventBody::RawFrame {
            json: frame(
                chat_id,
                "bridge-1",
                ts_ms + 500,
                "me",
                VibeFixtureKind::Text,
                "Continue",
            ),
        },
    ));
    out
}

fn escape_json(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_same_seed_produces_the_same_bytes() {
        let a = conversation("c", 42, 64, 1_000);
        let b = conversation("c", 42, 64, 1_000);
        assert_eq!(a.len(), b.len());
        for (x, y) in a.iter().zip(b.iter()) {
            match (&x.body, &y.body) {
                (VibeEventBody::RawFrame { json: j1 }, VibeEventBody::RawFrame { json: j2 }) => {
                    assert_eq!(j1, j2);
                }
                _ => panic!("unexpected fixture body"),
            }
        }
    }

    #[test]
    fn different_seeds_diverge() {
        let a = conversation("c", 1, 64, 1_000);
        let b = conversation("c", 2, 64, 1_000);
        let differs = a
            .iter()
            .zip(b.iter())
            .any(|(x, y)| match (&x.body, &y.body) {
                (VibeEventBody::RawFrame { json: j1 }, VibeEventBody::RawFrame { json: j2 }) => {
                    j1 != j2
                }
                _ => false,
            });
        assert!(differs);
    }

    #[test]
    fn every_generated_frame_is_valid_json() {
        for event in conversation("c", 7, 200, 0) {
            let VibeEventBody::RawFrame { json } = event.body else {
                panic!("unexpected body");
            };
            serde_json::from_slice::<serde_json::Value>(&json).expect("fixture must be valid json");
        }
    }

    #[test]
    fn escaping_survives_quotes_and_control_characters() {
        let json = frame(
            "c",
            "m1",
            1,
            "me",
            VibeFixtureKind::Text,
            "he said \"hi\"\n\tand\\left",
        );
        serde_json::from_slice::<serde_json::Value>(&json).expect("escaped fixture must parse");
    }

    #[test]
    fn history_page_is_a_json_array() {
        let event = history_page("c", 3, 50, 0, 0);
        let VibeEventBody::RawFrames { json_array } = event.body else {
            panic!("unexpected body");
        };
        let value: serde_json::Value = serde_json::from_slice(&json_array).unwrap();
        assert_eq!(value.as_array().unwrap().len(), 50);
    }
}
