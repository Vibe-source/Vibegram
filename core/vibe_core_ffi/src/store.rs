//! FFI surface for the sealed on-disk store (`vibe_core_store`).
//!
//! # Why this is a separate object from `VibeCoreHandle`
//!
//! The reducer's defining property is that it is *pure*: same events in, same
//! deltas out, no I/O, no clock, no disk. That is what makes replay and the soak
//! tests meaningful. Hanging SQLite off the reducer handle would quietly end
//! that, so the store is its own object with its own connection. The reducer
//! still never touches disk; the platform is what holds both handles.
//!
//! # Threading
//!
//! `rusqlite::Connection` is `Send` but not `Sync`, and a UniFFI object must be
//! both — hence the `Mutex`. That is not a workaround, it is the correct shape:
//! SQLite reads here are synchronous by nature, and the platform is expected to
//! call them from a background queue. **Calling these from the main thread is a
//! bug on the caller's side**, and the Swift wrapper refuses it loudly rather
//! than trading one main-thread stall (`ChatEngine.syncOnQueue`) for another.
//!
//! # Errors are never swallowed
//!
//! Every method returns `Result`. There is deliberately no "return empty on
//! failure" path: a store that silently reports zero rows is indistinguishable
//! from an empty chat, and that is precisely the bug class
//! [`VibeFfiChatLoadState`] exists to prevent.

use std::path::Path;
use std::sync::{Arc, Mutex};

use vibe_core_store::{
    VibeBackfillProgress, VibeChatLoadState, VibeCoreStore, VibeLegacyStore, VibeSealedRow,
    VibeStoreCursor, VibeStoreError,
};

use crate::seal::VibeStoreSealerHandle;
use crate::{guarded, VibeFfiError};

impl From<VibeStoreError> for VibeFfiError {
    fn from(value: VibeStoreError) -> Self {
        // `VibeStoreError` is `shapes, never data` by construction — its
        // `Display` cannot embed a path, SQL text, id, or payload — so
        // forwarding the rendered string keeps that guarantee.
        Self::Store {
            detail: value.to_string(),
        }
    }
}

/// One sealed row, exactly as it sits in `core_messages_v1`.
///
/// `sealed_body` and `seal_nonce` are opaque ciphertext. Nothing on this side of
/// the boundary inspects them; open them with [`VibeStoreSealerHandle::open`].
#[derive(Clone, Debug, uniffi::Record)]
pub struct VibeFfiStoredRow {
    pub message_id: String,
    pub ts_ms: i64,
    pub flags: i64,
    pub sealed_body: Vec<u8>,
    pub seal_nonce: Vec<u8>,
}

impl From<VibeSealedRow> for VibeFfiStoredRow {
    fn from(row: VibeSealedRow) -> Self {
        Self {
            message_id: row.message_id,
            ts_ms: row.ts_ms,
            flags: row.flags,
            sealed_body: row.sealed_body,
            seal_nonce: row.seal_nonce,
        }
    }
}

impl From<VibeFfiStoredRow> for VibeSealedRow {
    fn from(row: VibeFfiStoredRow) -> Self {
        Self {
            message_id: row.message_id,
            ts_ms: row.ts_ms,
            flags: row.flags,
            sealed_body: row.sealed_body,
            seal_nonce: row.seal_nonce,
        }
    }
}

/// Position in the total order, for paging.
#[derive(Clone, Debug, uniffi::Record)]
pub struct VibeFfiStoreCursor {
    pub ts_ms: i64,
    pub message_id: String,
}

impl From<VibeFfiStoreCursor> for VibeStoreCursor {
    fn from(cursor: VibeFfiStoreCursor) -> Self {
        Self {
            ts_ms: cursor.ts_ms,
            message_id: cursor.message_id,
        }
    }
}

/// Counts for one [`VibeStoreHandle::backfill_batch`] call — not cumulative.
#[derive(Clone, Copy, Debug, uniffi::Record)]
pub struct VibeFfiBackfillProgress {
    pub scanned: u64,
    pub written: u64,
    pub skipped: u64,
    pub done: bool,
}

impl From<VibeBackfillProgress> for VibeFfiBackfillProgress {
    fn from(progress: VibeBackfillProgress) -> Self {
        Self {
            scanned: progress.scanned,
            written: progress.written,
            skipped: progress.skipped,
            done: progress.done,
        }
    }
}

/// Three states, because "loaded and empty" and "never loaded" must not collapse.
///
/// Collapsing them is what made dormant chats open blank: an empty row array
/// read as "no history yet" instead of "history is known to be empty".
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum VibeFfiChatLoadState {
    NotLoaded,
    KnownEmpty,
    Loaded,
}

impl From<VibeChatLoadState> for VibeFfiChatLoadState {
    fn from(state: VibeChatLoadState) -> Self {
        match state {
            VibeChatLoadState::NotLoaded => Self::NotLoaded,
            VibeChatLoadState::KnownEmpty => Self::KnownEmpty,
            VibeChatLoadState::Loaded => Self::Loaded,
        }
    }
}

impl From<VibeFfiChatLoadState> for VibeChatLoadState {
    fn from(state: VibeFfiChatLoadState) -> Self {
        match state {
            VibeFfiChatLoadState::NotLoaded => Self::NotLoaded,
            VibeFfiChatLoadState::KnownEmpty => Self::KnownEmpty,
            VibeFfiChatLoadState::Loaded => Self::Loaded,
        }
    }
}

/// Read-only handle onto the shipped app's `messages` table.
///
/// Opened `SQLITE_OPEN_READ_ONLY`. The app stays the sole writer; this exists so
/// backfill can walk what is already on disk without a second source of truth.
#[derive(uniffi::Object)]
pub struct VibeLegacyStoreHandle {
    inner: Mutex<VibeLegacyStore>,
}

#[uniffi::export]
impl VibeLegacyStoreHandle {
    /// Opens an existing database. A missing file is `NotFound`, never created.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>, VibeFfiError> {
        guarded("legacy_store_open", || {
            let store = VibeLegacyStore::open(Path::new(&path))?;
            Ok(Arc::new(Self {
                inner: Mutex::new(store),
            }))
        })
    }

    /// Total durable rows visible for `(user_id, chat_id)` in the legacy table.
    pub fn count(&self, user_id: String, chat_id: String) -> Result<u64, VibeFfiError> {
        guarded("legacy_store_count", || {
            Ok(self.locked()?.count(&user_id, &chat_id)?)
        })
    }

    /// Message ids of the newest `limit` rows, ascending.
    ///
    /// Ids only, deliberately: this exists to compare the two tables, and
    /// hauling sealed payload bytes across the boundary to do it would copy the
    /// whole transcript to answer a question about ordering.
    pub fn newest_message_ids(
        &self,
        user_id: String,
        chat_id: String,
        limit: u32,
    ) -> Result<Vec<String>, VibeFfiError> {
        guarded("legacy_store_newest_message_ids", || {
            let rows = self.locked()?.page_before(&user_id, &chat_id, None, limit)?;
            Ok(rows.into_iter().map(|row| row.message_id).collect())
        })
    }
}

impl VibeLegacyStoreHandle {
    fn locked(&self) -> Result<std::sync::MutexGuard<'_, VibeLegacyStore>, VibeFfiError> {
        // A poisoned mutex means a previous call panicked while holding it. The
        // connection itself is still usable, but reporting `Internal` tells the
        // platform to fall back rather than trust a store whose last operation
        // tore halfway through.
        self.inner.lock().map_err(|_| VibeFfiError::Internal {
            detail: "legacy store mutex poisoned".to_string(),
        })
    }
}

/// Read-write handle onto the sealed core tables.
#[derive(uniffi::Object)]
pub struct VibeStoreHandle {
    inner: Mutex<VibeCoreStore>,
}

#[uniffi::export]
impl VibeStoreHandle {
    /// Opens (or creates) the database and ensures the additive schema exists.
    ///
    /// Never touches the legacy `messages` table — that is the rollback surface.
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Arc<Self>, VibeFfiError> {
        guarded("store_open", || {
            let store = VibeCoreStore::open(Path::new(&path))?;
            Ok(Arc::new(Self {
                inner: Mutex::new(store),
            }))
        })
    }

    /// Upserts a batch under one exclusive transaction.
    ///
    /// Idempotent, and safe to kill mid-batch: a partial batch rolls back whole.
    pub fn upsert(
        &self,
        user_id: String,
        chat_id: String,
        rows: Vec<VibeFfiStoredRow>,
    ) -> Result<(), VibeFfiError> {
        guarded("store_upsert", || {
            let rows: Vec<VibeSealedRow> = rows.into_iter().map(Into::into).collect();
            Ok(self.locked()?.upsert(&user_id, &chat_id, &rows)?)
        })
    }

    /// The page immediately before `before`, ascending. `None` → newest page.
    pub fn page_before(
        &self,
        user_id: String,
        chat_id: String,
        before: Option<VibeFfiStoreCursor>,
        limit: u32,
    ) -> Result<Vec<VibeFfiStoredRow>, VibeFfiError> {
        guarded("store_page_before", || {
            let rows =
                self.locked()?
                    .page_before(&user_id, &chat_id, before.map(Into::into), limit)?;
            Ok(rows.into_iter().map(Into::into).collect())
        })
    }

    /// The page immediately after `after`, ascending. `None` → oldest page.
    pub fn page_after(
        &self,
        user_id: String,
        chat_id: String,
        after: Option<VibeFfiStoreCursor>,
        limit: u32,
    ) -> Result<Vec<VibeFfiStoredRow>, VibeFfiError> {
        guarded("store_page_after", || {
            let rows = self
                .locked()?
                .page_after(&user_id, &chat_id, after.map(Into::into), limit)?;
            Ok(rows.into_iter().map(Into::into).collect())
        })
    }

    /// Records tombstones for `ids`.
    pub fn tombstone(
        &self,
        user_id: String,
        chat_id: String,
        ids: Vec<String>,
        at_ms: i64,
        for_everyone: bool,
    ) -> Result<(), VibeFfiError> {
        guarded("store_tombstone", || {
            let refs: Vec<&str> = ids.iter().map(String::as_str).collect();
            Ok(self
                .locked()?
                .tombstone(&user_id, &chat_id, &refs, at_ms, for_everyone)?)
        })
    }

    /// Whether this address carries a tombstone.
    pub fn is_tombstoned(
        &self,
        user_id: String,
        chat_id: String,
        message_id: String,
    ) -> Result<bool, VibeFfiError> {
        guarded("store_is_tombstoned", || {
            Ok(self.locked()?.is_tombstoned(&user_id, &chat_id, &message_id)?)
        })
    }

    /// Sealed row count for `(user_id, chat_id)`.
    pub fn count(&self, user_id: String, chat_id: String) -> Result<u64, VibeFfiError> {
        guarded("store_count", || {
            Ok(self.locked()?.count(&user_id, &chat_id)?)
        })
    }

    /// Message ids of the newest `limit` rows, ascending — the counterpart to
    /// [`VibeLegacyStoreHandle::newest_message_ids`], for comparing the two.
    pub fn newest_message_ids(
        &self,
        user_id: String,
        chat_id: String,
        limit: u32,
    ) -> Result<Vec<String>, VibeFfiError> {
        guarded("store_newest_message_ids", || {
            let rows = self.locked()?.page_before(&user_id, &chat_id, None, limit)?;
            Ok(rows.into_iter().map(|row| row.message_id).collect())
        })
    }

    /// Drops everything but the newest `keep_newest` rows. `0` clears the chat.
    pub fn prune(
        &self,
        user_id: String,
        chat_id: String,
        keep_newest: u32,
    ) -> Result<(), VibeFfiError> {
        guarded("store_prune", || {
            Ok(self.locked()?.prune(&user_id, &chat_id, keep_newest)?)
        })
    }

    /// The durable load decision for a chat.
    pub fn load_state(
        &self,
        user_id: String,
        chat_id: String,
    ) -> Result<VibeFfiChatLoadState, VibeFfiError> {
        guarded("store_load_state", || {
            Ok(self.locked()?.load_state(&user_id, &chat_id)?.into())
        })
    }

    /// Persists the load decision. `NotLoaded` clears it.
    pub fn set_load_state(
        &self,
        user_id: String,
        chat_id: String,
        state: VibeFfiChatLoadState,
    ) -> Result<(), VibeFfiError> {
        guarded("store_set_load_state", || {
            Ok(self
                .locked()?
                .set_load_state(&user_id, &chat_id, state.into())?)
        })
    }

    /// Reads an opaque meta value. The store never interprets these bytes.
    pub fn meta_get(&self, key: String) -> Result<Option<Vec<u8>>, VibeFfiError> {
        guarded("store_meta_get", || Ok(self.locked()?.meta_get(&key)?))
    }

    /// Writes an opaque meta value.
    pub fn meta_set(&self, key: String, value: Vec<u8>) -> Result<(), VibeFfiError> {
        guarded("store_meta_set", || Ok(self.locked()?.meta_set(&key, &value)?))
    }

    /// Seals one batch of legacy rows into the core tables, newest-first.
    ///
    /// Call repeatedly until `done`. The resume cursor commits in the same
    /// transaction as the rows, so this is safe to interrupt at any point.
    pub fn backfill_batch(
        &self,
        legacy: Arc<VibeLegacyStoreHandle>,
        user_id: String,
        chat_id: String,
        sealer: Arc<VibeStoreSealerHandle>,
        batch_limit: u32,
    ) -> Result<VibeFfiBackfillProgress, VibeFfiError> {
        guarded("store_backfill_batch", || {
            // Always core-then-legacy. This is the only method that holds both,
            // so a single consistent order is all deadlock-freedom requires.
            let store = self.locked()?;
            let legacy = legacy.locked()?;
            let progress =
                store.backfill_batch(&legacy, &user_id, &chat_id, sealer.as_ref(), batch_limit)?;
            Ok(progress.into())
        })
    }

    /// Clears the resume cursor so the next batch restarts from the newest row.
    pub fn reset_backfill_cursor(
        &self,
        user_id: String,
        chat_id: String,
    ) -> Result<(), VibeFfiError> {
        guarded("store_reset_backfill_cursor", || {
            Ok(self.locked()?.reset_backfill_cursor(&user_id, &chat_id)?)
        })
    }
}

impl VibeStoreHandle {
    fn locked(&self) -> Result<std::sync::MutexGuard<'_, VibeCoreStore>, VibeFfiError> {
        self.inner.lock().map_err(|_| VibeFfiError::Internal {
            detail: "core store mutex poisoned".to_string(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_db(name: &str) -> std::path::PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!(
            "vibe_ffi_store_{name}_{}.sqlite",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        path
    }

    fn sealer() -> Arc<VibeStoreSealerHandle> {
        VibeStoreSealerHandle::new(vec![0x5A; 32]).expect("32-byte key is accepted")
    }

    fn row(id: &str, ts_ms: i64) -> VibeFfiStoredRow {
        let sealed = sealer()
            .seal(
                "u1".to_string(),
                "c1".to_string(),
                id.to_string(),
                b"{\"text\":\"hi\"}".to_vec(),
            )
            .expect("seal succeeds");
        VibeFfiStoredRow {
            message_id: id.to_string(),
            ts_ms,
            flags: 0,
            sealed_body: sealed.sealed_body,
            seal_nonce: sealed.seal_nonce,
        }
    }

    #[test]
    fn a_round_trip_through_the_boundary_preserves_order_and_bytes() {
        let path = temp_db("round_trip");
        let store = VibeStoreHandle::open(path.to_string_lossy().to_string()).expect("opens");

        let rows = vec![row("m1", 1_000), row("m2", 2_000), row("m3", 3_000)];
        store
            .upsert("u1".to_string(), "c1".to_string(), rows.clone())
            .expect("upsert succeeds");

        assert_eq!(
            store.count("u1".to_string(), "c1".to_string()).expect("count"),
            3
        );

        let page = store
            .page_before("u1".to_string(), "c1".to_string(), None, 10)
            .expect("page_before");
        let ids: Vec<&str> = page.iter().map(|r| r.message_id.as_str()).collect();
        assert_eq!(ids, ["m1", "m2", "m3"], "newest page comes back ascending");

        // The sealed bytes must survive the boundary untouched, or `open` fails.
        let opened = sealer()
            .open(
                "u1".to_string(),
                "c1".to_string(),
                "m2".to_string(),
                page[1].sealed_body.clone(),
                page[1].seal_nonce.clone(),
            )
            .expect("opens at the address it was sealed for");
        assert_eq!(opened, b"{\"text\":\"hi\"}");

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn load_state_survives_reopen_and_never_collapses_to_empty() {
        let path = temp_db("load_state");
        let db = path.to_string_lossy().to_string();

        {
            let store = VibeStoreHandle::open(db.clone()).expect("opens");
            assert_eq!(
                store
                    .load_state("u1".to_string(), "c1".to_string())
                    .expect("load_state"),
                VibeFfiChatLoadState::NotLoaded,
                "a chat nobody has loaded is NotLoaded, not KnownEmpty"
            );
            store
                .set_load_state(
                    "u1".to_string(),
                    "c1".to_string(),
                    VibeFfiChatLoadState::KnownEmpty,
                )
                .expect("set_load_state");
        }

        // Reopen: this is the cold-launch path that used to read as "no history".
        let store = VibeStoreHandle::open(db).expect("reopens");
        assert_eq!(
            store
                .load_state("u1".to_string(), "c1".to_string())
                .expect("load_state"),
            VibeFfiChatLoadState::KnownEmpty
        );
        assert_eq!(
            store.count("u1".to_string(), "c1".to_string()).expect("count"),
            0,
            "known-empty and zero rows are independent facts"
        );

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn opening_a_missing_legacy_store_is_an_error_not_an_empty_store() {
        let mut path = std::env::temp_dir();
        path.push("vibe_ffi_store_definitely_absent.sqlite");
        let _ = std::fs::remove_file(&path);

        let result = VibeLegacyStoreHandle::open(path.to_string_lossy().to_string());
        assert!(
            result.is_err(),
            "a missing legacy DB must surface, never masquerade as a chat with no history"
        );
    }
}
