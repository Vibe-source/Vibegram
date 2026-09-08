//! Read-only handle onto the shipped `messages` table.
//!
//! The safety property of this module is structural: the connection is opened
//! with [`OpenFlags::SQLITE_OPEN_READ_ONLY`] only. There is no code path that
//! can `INSERT`, `UPDATE`, `DELETE`, create tables, or change journal mode.

use std::path::Path;
use std::time::Duration;

use rusqlite::{params, Connection, OpenFlags};

use crate::error::{map_open_error, map_query_error, VibeStoreError};

/// Hard ceiling on any page request. A bad caller cannot pull an unbounded set.
pub const MAX_PAGE_LIMIT: u32 = 1000;

/// Busy-timeout matching `ChatMessageStore` (`PRAGMA busy_timeout=2000`).
const BUSY_TIMEOUT: Duration = Duration::from_millis(2000);

/// One stored message row. `payload` is opaque bytes — never parsed here.
#[derive(Clone, PartialEq, Eq)]
pub struct VibeStoredRow {
    pub message_id: String,
    pub ts_ms: i64,
    pub payload: Vec<u8>,
}

impl std::fmt::Debug for VibeStoredRow {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Length only — payload bytes must not appear in diagnostics.
        f.debug_struct("VibeStoredRow")
            .field("message_id", &self.message_id)
            .field("ts_ms", &self.ts_ms)
            .field("payload_len", &self.payload.len())
            .finish()
    }
}

/// Cursor into the total order `(ts_ms ASC, message_id ASC)`.
///
/// Comparison is the full tuple — same-millisecond messages are common and a
/// `ts`-only cursor silently drops rows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VibeStoreCursor {
    pub ts_ms: i64,
    pub message_id: String,
}

/// Read-only view onto the app's on-disk message store.
///
/// Opened with `SQLITE_OPEN_READ_ONLY` only. The app remains the sole writer.
pub struct VibeLegacyStore {
    conn: Connection,
}

impl std::fmt::Debug for VibeLegacyStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never include the path — the connection may hold it internally, but
        // our Debug surface is a shape only.
        f.write_str("VibeLegacyStore")
    }
}

impl VibeLegacyStore {
    /// Open an existing database file for reading only.
    ///
    /// Returns [`VibeStoreError::NotFound`] when the path does not exist or
    /// cannot be opened as a database. Never creates a file.
    pub fn open(path: &Path) -> Result<Self, VibeStoreError> {
        // Explicit existence check so a missing path is always `NotFound`, not
        // a generic open failure that might embed the path in a rusqlite string
        // we then discard — callers get a stable typed error either way.
        if !path.exists() {
            return Err(VibeStoreError::NotFound);
        }

        let flags = OpenFlags::SQLITE_OPEN_READ_ONLY;
        // Deliberately no SQLITE_OPEN_CREATE, no READ_WRITE.
        let conn = Connection::open_with_flags(path, flags).map_err(|e| map_open_error(&e))?;

        conn.busy_timeout(BUSY_TIMEOUT)
            .map_err(|e| map_open_error(&e))?;

        Ok(Self { conn })
    }

    /// Number of stored rows for `(user_id, chat_id)`.
    ///
    /// A chat that has never been written returns `0` (not an error). Callers
    /// that need "known chat" vs "never seen" can combine this with
    /// [`Self::chat_ids`]: a chat with `count == 0` does not appear in
    /// `chat_ids`, while a chat that still has rows will.
    pub fn count(&self, user_id: &str, chat_id: &str) -> Result<u64, VibeStoreError> {
        let n: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM messages WHERE user_id = ?1 AND chat_id = ?2",
                params![user_id, chat_id],
                |row| row.get(0),
            )
            .map_err(|e| map_query_error(&e))?;
        Ok(u64::try_from(n).unwrap_or(0))
    }

    /// Distinct `chat_id` values that have at least one row for `user_id`,
    /// ordered ascending for stable iteration.
    pub fn chat_ids(&self, user_id: &str) -> Result<Vec<String>, VibeStoreError> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT DISTINCT chat_id FROM messages WHERE user_id = ?1 ORDER BY chat_id ASC",
            )
            .map_err(|e| map_query_error(&e))?;
        let rows = stmt
            .query_map(params![user_id], |row| row.get::<_, String>(0))
            .map_err(|e| map_query_error(&e))?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row.map_err(|e| map_query_error(&e))?);
        }
        Ok(out)
    }

    /// Rows immediately preceding `before` in the total order, returned in
    /// **ascending** order (not reversed).
    ///
    /// - `before = None` → newest page (the tail of the chat).
    /// - `limit` is clamped to [`MAX_PAGE_LIMIT`]. A zero limit yields an empty vec.
    /// - An empty or never-written chat yields `Ok([])`, not an error.
    pub fn page_before(
        &self,
        user_id: &str,
        chat_id: &str,
        before: Option<VibeStoreCursor>,
        limit: u32,
    ) -> Result<Vec<VibeStoredRow>, VibeStoreError> {
        let limit = clamp_limit(limit);
        if limit == 0 {
            return Ok(Vec::new());
        }

        match before {
            None => {
                // Newest `limit` rows, re-ordered ascending — matches Swift
                // `recentMessagePayloads`.
                self.query_rows(
                    r"
                    SELECT message_id, ts, payload FROM (
                      SELECT message_id, ts, payload FROM messages
                      WHERE user_id = ?1 AND chat_id = ?2
                      ORDER BY ts DESC, message_id DESC
                      LIMIT ?3
                    )
                    ORDER BY ts ASC, message_id ASC
                    ",
                    params![user_id, chat_id, limit],
                )
            }
            Some(cursor) => {
                // Strictly before the cursor tuple, take the nearest `limit`
                // rows, return ascending — matches Swift `olderMessagePayloads`.
                self.query_rows(
                    r"
                    SELECT message_id, ts, payload FROM (
                      SELECT message_id, ts, payload FROM messages
                      WHERE user_id = ?1 AND chat_id = ?2
                        AND (ts < ?3 OR (ts = ?3 AND message_id < ?4))
                      ORDER BY ts DESC, message_id DESC
                      LIMIT ?5
                    )
                    ORDER BY ts ASC, message_id ASC
                    ",
                    params![user_id, chat_id, cursor.ts_ms, cursor.message_id, limit],
                )
            }
        }
    }

    /// Rows immediately following `after` in the total order, ascending.
    ///
    /// - `after = None` → oldest page (the head of the chat).
    /// - `limit` is clamped to [`MAX_PAGE_LIMIT`]. A zero limit yields an empty vec.
    /// - An empty or never-written chat yields `Ok([])`, not an error.
    pub fn page_after(
        &self,
        user_id: &str,
        chat_id: &str,
        after: Option<VibeStoreCursor>,
        limit: u32,
    ) -> Result<Vec<VibeStoredRow>, VibeStoreError> {
        let limit = clamp_limit(limit);
        if limit == 0 {
            return Ok(Vec::new());
        }

        match after {
            None => self.query_rows(
                r"
                SELECT message_id, ts, payload FROM messages
                WHERE user_id = ?1 AND chat_id = ?2
                ORDER BY ts ASC, message_id ASC
                LIMIT ?3
                ",
                params![user_id, chat_id, limit],
            ),
            Some(cursor) => self.query_rows(
                r"
                SELECT message_id, ts, payload FROM messages
                WHERE user_id = ?1 AND chat_id = ?2
                  AND (ts > ?3 OR (ts = ?3 AND message_id > ?4))
                ORDER BY ts ASC, message_id ASC
                LIMIT ?5
                ",
                params![user_id, chat_id, cursor.ts_ms, cursor.message_id, limit],
            ),
        }
    }

    fn query_rows(
        &self,
        sql: &str,
        params: impl rusqlite::Params,
    ) -> Result<Vec<VibeStoredRow>, VibeStoreError> {
        let mut stmt = self.conn.prepare(sql).map_err(|e| map_query_error(&e))?;
        let mapped = stmt
            .query_map(params, |row| {
                let message_id: String = row.get(0)?;
                let ts_ms: i64 = row.get(1)?;
                let payload: Vec<u8> = row.get(2)?;
                Ok(VibeStoredRow {
                    message_id,
                    ts_ms,
                    payload,
                })
            })
            .map_err(|e| map_query_error(&e))?;

        let mut out = Vec::new();
        for row in mapped {
            out.push(row.map_err(|e| map_query_error(&e))?);
        }
        Ok(out)
    }
}

fn clamp_limit(limit: u32) -> u32 {
    limit.min(MAX_PAGE_LIMIT)
}
