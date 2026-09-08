//! Storage for Vibe message history.
//!
//! Two independent handles share a SQLite file but never share tables:
//!
//! - [`VibeLegacyStore`] — read-only view of the shipped app `messages` table.
//! - [`VibeCoreStore`] — read-write sealed store (`core_messages_v1` and friends).
//!
//! The legacy table is the rollback surface. `VibeCoreStore` never reads or
//! writes it. Sealed body/nonce bytes are opaque; this crate does no crypto.

#![forbid(unsafe_code)]

mod core_store;
mod error;
mod store;

pub use core_store::{
    VibeBackfillProgress, VibeChatLoadState, VibeCoreStore, VibeRowSealer, VibeSealedRow,
};
pub use error::VibeStoreError;
pub use store::{VibeLegacyStore, VibeStoreCursor, VibeStoredRow, MAX_PAGE_LIMIT};
