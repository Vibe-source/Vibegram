//! Typed store errors.
//!
//! Governing rule (shared with `vibe_core`): **shapes, never data.** No variant
//! may carry SQL text, file paths, message ids, or payload bytes. `Display` and
//! `Debug` are both free of those.

/// Failure of a read-only store operation.
///
/// Every variant names a *shape* problem. None of them can be constructed with
/// user- or disk-supplied strings inside.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VibeStoreError {
    /// Path does not exist, or is not openable as a readable SQLite database.
    NotFound,
    /// Open failed for a reason other than absence (permissions, not a database).
    OpenFailed,
    /// A statement timed out waiting for a writer lock (`busy_timeout`).
    Busy,
    /// A prepared statement or step failed (schema missing, I/O, etc.).
    QueryFailed,
}

impl std::fmt::Display for VibeStoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound => f.write_str("store not found"),
            Self::OpenFailed => f.write_str("store open failed"),
            Self::Busy => f.write_str("store busy"),
            Self::QueryFailed => f.write_str("store query failed"),
        }
    }
}

impl std::error::Error for VibeStoreError {}

/// Map a `rusqlite` error from `open` into a shape-only variant.
///
/// The underlying error string is deliberately discarded: it often embeds the
/// path the caller supplied.
pub(crate) fn map_open_error(err: &rusqlite::Error) -> VibeStoreError {
    match err {
        rusqlite::Error::SqliteFailure(code, _) => match code.code {
            rusqlite::ErrorCode::CannotOpen | rusqlite::ErrorCode::NotFound => {
                VibeStoreError::NotFound
            }
            rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked => {
                VibeStoreError::Busy
            }
            _ => VibeStoreError::OpenFailed,
        },
        // Path-related failures from the OS layer also surface here.
        rusqlite::Error::InvalidPath(_) => VibeStoreError::NotFound,
        _ => VibeStoreError::OpenFailed,
    }
}

/// Map a `rusqlite` error from a statement into a shape-only variant.
pub(crate) fn map_query_error(err: &rusqlite::Error) -> VibeStoreError {
    match err {
        rusqlite::Error::SqliteFailure(code, _) => match code.code {
            rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked => {
                VibeStoreError::Busy
            }
            _ => VibeStoreError::QueryFailed,
        },
        _ => VibeStoreError::QueryFailed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_display_and_debug_carry_no_data_slots() {
        for e in [
            VibeStoreError::NotFound,
            VibeStoreError::OpenFailed,
            VibeStoreError::Busy,
            VibeStoreError::QueryFailed,
        ] {
            let rendered = format!("{e} {e:?}");
            // No path separators, no SQL keywords that would appear if we
            // forwarded rusqlite messages, no payload-ish markers.
            assert!(!rendered.contains('/'));
            assert!(!rendered.contains('\\'));
            assert!(!rendered.contains("SELECT"));
            assert!(!rendered.contains("payload"));
        }
    }
}
