//! Shared test scaffolding. Synthetic only — no production data, no real keys.

#![allow(dead_code)]

use std::sync::Arc;

use vibe_core::crypto::{VibeKeyUnwrapper, VibeWrappedKeyRequest};
use vibe_core::fixtures::{self, VibeFixtureKind};
use vibe_core::secret::VibeSecretKey;
use vibe_core::{
    VibeChatClass, VibeChatProfile, VibeCoreConfig, VibeCoreEventV1, VibeEventBody,
    VibeEventSource, VibeTimelineReducer,
};

pub const CHAT: &str = "chat-1";
pub const ME: &str = "me";
pub const PEER: &str = "peer";

/// Base timestamp for fixtures, in epoch milliseconds.
///
/// Deliberately a realistic value: the canonicalizer promotes any timestamp
/// below 1e11 from seconds to milliseconds (the wire carries both), so tiny
/// synthetic timestamps would be silently multiplied by 1000 and every
/// assertion about `ts_ms` would be testing the wrong thing.
pub const T0: i64 = 1_785_000_000_000;

/// A key unwrapper that always returns the same synthetic key.
///
/// Stands in for the platform's Keychain/Keystore seam. It never performs an RSA
/// operation, because this crate never does.
pub struct FixedKeyUnwrapper(pub [u8; 32]);

impl VibeKeyUnwrapper for FixedKeyUnwrapper {
    fn unwrap_aes_keys(&self, requests: &[VibeWrappedKeyRequest]) -> Vec<Option<VibeSecretKey>> {
        requests
            .iter()
            .map(|_| Some(VibeSecretKey::from_bytes(self.0)))
            .collect()
    }
}

pub fn config() -> VibeCoreConfig {
    VibeCoreConfig {
        own_user_id: ME.to_string(),
        ..VibeCoreConfig::default()
    }
}

pub fn reducer() -> VibeTimelineReducer {
    reducer_for(VibeChatClass::DirectMessage)
}

/// A reducer with the bounded window policy — same as [`reducer`], named for the tests
/// that are specifically about paging and tail eviction so their intent survives any
/// future change to what the default is.
pub fn bounded_reducer() -> VibeTimelineReducer {
    reducer()
}

/// A reducer whose window has **no ceiling**: the mounted set is the whole store.
///
/// Not the shipping default. A bounded window is what keeps the renderer's commit
/// constant-cost; this exists for callers that genuinely want everything mounted, and
/// for the tests that pin what unbounded means.
pub fn unbounded_reducer() -> VibeTimelineReducer {
    let mut r = VibeTimelineReducer::new(VibeCoreConfig {
        own_user_id: ME.to_string(),
        window_policy: vibe_core::window::VibeWindowPolicy::unbounded(),
        ..VibeCoreConfig::default()
    });
    r.set_chat_profile(CHAT, VibeChatProfile::default());
    r
}

pub fn reducer_for(class: VibeChatClass) -> VibeTimelineReducer {
    let mut r = VibeTimelineReducer::new(config());
    r.set_chat_profile(
        CHAT,
        VibeChatProfile {
            class,
            ..VibeChatProfile::default()
        },
    );
    r
}

pub fn reducer_with_keys() -> VibeTimelineReducer {
    let mut r = VibeTimelineReducer::new(VibeCoreConfig {
        own_user_id: ME.to_string(),
        unwrapper: Arc::new(FixedKeyUnwrapper([42u8; 32])),
        ..VibeCoreConfig::default()
    });
    r.set_chat_profile(CHAT, VibeChatProfile::default());
    r
}

pub fn text_event(id: &str, ts: i64, sender: &str, text: &str) -> VibeCoreEventV1 {
    VibeCoreEventV1::new(
        CHAT,
        ts,
        VibeEventSource::ChatTopic,
        VibeEventBody::RawFrame {
            json: fixtures::frame(CHAT, id, ts, sender, VibeFixtureKind::Text, text),
        },
    )
}

pub fn event_from(
    source: VibeEventSource,
    id: &str,
    ts: i64,
    sender: &str,
    text: &str,
) -> VibeCoreEventV1 {
    VibeCoreEventV1::new(
        CHAT,
        ts,
        source,
        VibeEventBody::RawFrame {
            json: fixtures::frame(CHAT, id, ts, sender, VibeFixtureKind::Text, text),
        },
    )
}

/// Ingests then flushes, returning the ids currently in the window.
pub fn window_ids(reducer: &VibeTimelineReducer) -> Vec<String> {
    reducer
        .current_window(CHAT)
        .expect("chat exists")
        .messages
        .iter()
        .map(|m| m.message_id.clone())
        .collect()
}

/// Feeds a whole event list and flushes once at the end.
pub fn drive(reducer: &mut VibeTimelineReducer, events: Vec<VibeCoreEventV1>, now_ms: i64) {
    for event in events {
        reducer.ingest(event);
    }
    reducer.flush(now_ms);
}
