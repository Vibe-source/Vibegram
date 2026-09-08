//! Integration tests against a temp DB with the shipped `messages` schema.
//!
//! Seeding uses a separate write connection. The crate under test opens
//! read-only only — never against a path that does not already exist as a DB.

use std::collections::HashSet;
use std::path::Path;

use rusqlite::Connection;
use tempfile::{NamedTempFile, TempDir};
use vibe_core_store::{
    VibeLegacyStore, VibeStoreCursor, VibeStoreError, VibeStoredRow, MAX_PAGE_LIMIT,
};

const USER: &str = "user-a";
const CHAT: &str = "chat-1";
const OTHER_CHAT: &str = "chat-2";

fn create_schema(conn: &Connection) {
    conn.execute_batch(
        r"
        CREATE TABLE messages(
          user_id    TEXT NOT NULL,
          chat_id    TEXT NOT NULL,
          message_id TEXT NOT NULL,
          ts         INTEGER NOT NULL,
          payload    BLOB NOT NULL,
          PRIMARY KEY(user_id, chat_id, message_id)
        );
        CREATE INDEX idx_messages_chat_ts ON messages(user_id, chat_id, ts);
        ",
    )
    .expect("create schema");
}

fn insert_row(conn: &Connection, user: &str, chat: &str, id: &str, ts: i64, payload: &[u8]) {
    conn.execute(
        "INSERT INTO messages(user_id, chat_id, message_id, ts, payload) VALUES(?1,?2,?3,?4,?5)",
        rusqlite::params![user, chat, id, ts, payload],
    )
    .expect("insert");
}

/// Build a temp DB, seed with the given rows, open read-only.
fn seeded(rows: &[(&str, &str, &str, i64, &[u8])]) -> (NamedTempFile, VibeLegacyStore) {
    let tmp = NamedTempFile::new().expect("tempfile");
    {
        let conn = Connection::open(tmp.path()).expect("write open");
        create_schema(&conn);
        for (user, chat, id, ts, payload) in rows {
            insert_row(&conn, user, chat, id, *ts, payload);
        }
    }
    let store = VibeLegacyStore::open(tmp.path()).expect("read-only open");
    (tmp, store)
}

fn cursor(row: &VibeStoredRow) -> VibeStoreCursor {
    VibeStoreCursor {
        ts_ms: row.ts_ms,
        message_id: row.message_id.clone(),
    }
}

fn ids(rows: &[VibeStoredRow]) -> Vec<&str> {
    rows.iter().map(|r| r.message_id.as_str()).collect()
}

/// Assert total order: ts ASC, then message_id ASC (byte-wise).
fn assert_ascending(rows: &[VibeStoredRow]) {
    for w in rows.windows(2) {
        let a = &w[0];
        let b = &w[1];
        assert!(
            a.ts_ms < b.ts_ms || (a.ts_ms == b.ts_ms && a.message_id < b.message_id),
            "order broken: ({}, {}) then ({}, {})",
            a.ts_ms,
            a.message_id,
            b.ts_ms,
            b.message_id
        );
    }
}

// ---------------------------------------------------------------------------
// Open
// ---------------------------------------------------------------------------

#[test]
fn open_nonexistent_file_is_typed_error_not_panic() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("no-such-file.db");
    assert!(!path.exists());
    let err = VibeLegacyStore::open(&path).unwrap_err();
    assert_eq!(err, VibeStoreError::NotFound);
    // Shape only — no path leakage.
    let rendered = format!("{err} {err:?}");
    assert!(!rendered.contains(path.to_string_lossy().as_ref()));
    assert!(!rendered.contains("no-such-file"));
}

#[test]
fn open_empty_directory_path_is_error() {
    let dir = TempDir::new().unwrap();
    // Path exists but is a directory, not a database file.
    let err = VibeLegacyStore::open(dir.path()).unwrap_err();
    assert!(
        matches!(err, VibeStoreError::NotFound | VibeStoreError::OpenFailed),
        "unexpected: {err:?}"
    );
}

// ---------------------------------------------------------------------------
// Order including same-ts tie-break
// ---------------------------------------------------------------------------

#[test]
fn ascending_order_holds_including_same_ts_tiebreak() {
    // Same ts, ids that sort as a < b < c by byte order.
    let payload = b"x";
    let (_tmp, store) = seeded(&[
        (USER, CHAT, "m-c", 100, payload),
        (USER, CHAT, "m-a", 100, payload),
        (USER, CHAT, "m-b", 100, payload),
        (USER, CHAT, "m-z", 50, payload),
        (USER, CHAT, "m-y", 200, payload),
    ]);

    let page = store.page_after(USER, CHAT, None, 100).unwrap();
    assert_eq!(ids(&page), ["m-z", "m-a", "m-b", "m-c", "m-y"]);
    assert_ascending(&page);

    let newest = store.page_before(USER, CHAT, None, 100).unwrap();
    assert_eq!(ids(&newest), ["m-z", "m-a", "m-b", "m-c", "m-y"]);
    assert_ascending(&newest);
}

// ---------------------------------------------------------------------------
// Full-chat paging consistency both directions
// ---------------------------------------------------------------------------

#[test]
fn page_before_and_page_after_cover_every_row_exactly_once() {
    let payload = b"p";
    // 12 rows across a few timestamps, including same-ts pairs.
    let mut seed: Vec<(&str, &str, &str, i64, &[u8])> = Vec::new();
    let id_storage: Vec<String> = (0..12).map(|i| format!("id-{i:02}")).collect();
    for (i, id) in id_storage.iter().enumerate() {
        // ts groups: 0,0,1,1,2,2,... so same-ms pairs exist.
        let ts = (i as i64 / 2) * 10;
        seed.push((USER, CHAT, id.as_str(), ts, payload));
    }
    let (_tmp, store) = seeded(&seed);

    let total = store.count(USER, CHAT).unwrap();
    assert_eq!(total, 12);

    // Forward: page_after from None, limit 3.
    let mut forward: Vec<VibeStoredRow> = Vec::new();
    let mut after: Option<VibeStoreCursor> = None;
    loop {
        let page = store.page_after(USER, CHAT, after, 3).unwrap();
        if page.is_empty() {
            break;
        }
        assert!(page.len() <= 3);
        assert_ascending(&page);
        after = Some(cursor(page.last().unwrap()));
        forward.extend(page);
    }
    assert_eq!(forward.len(), 12);
    assert_ascending(&forward);
    let fwd_ids: HashSet<_> = forward.iter().map(|r| r.message_id.clone()).collect();
    assert_eq!(fwd_ids.len(), 12, "forward paging introduced duplicates");

    // Backward: page_before from None, limit 3.
    let mut backward_pages: Vec<Vec<VibeStoredRow>> = Vec::new();
    let mut before: Option<VibeStoreCursor> = None;
    loop {
        let page = store.page_before(USER, CHAT, before, 3).unwrap();
        if page.is_empty() {
            break;
        }
        assert!(page.len() <= 3);
        assert_ascending(&page);
        before = Some(cursor(page.first().unwrap()));
        backward_pages.push(page);
    }
    // Pages arrive newest-first as batches; flatten and sort to compare set.
    let mut backward: Vec<VibeStoredRow> = backward_pages.into_iter().flatten().collect();
    // Should be 12 unique rows.
    let back_ids: HashSet<_> = backward.iter().map(|r| r.message_id.clone()).collect();
    assert_eq!(back_ids.len(), 12, "backward paging introduced duplicates");
    assert_eq!(back_ids, fwd_ids, "before/after saw different row sets");

    // Reconstruct chronological order from backward pages: each page is ascending
    // and pages walk from tail toward head, so reverse the page sequence.
    // Easier: sort the collected rows and match forward.
    backward.sort_by(|a, b| {
        a.ts_ms
            .cmp(&b.ts_ms)
            .then_with(|| a.message_id.cmp(&b.message_id))
    });
    assert_eq!(ids(&backward), ids(&forward));
}

#[test]
fn page_before_with_cursor_returns_preceding_rows_ascending() {
    let payload = b"x";
    let (_tmp, store) = seeded(&[
        (USER, CHAT, "a", 1, payload),
        (USER, CHAT, "b", 2, payload),
        (USER, CHAT, "c", 3, payload),
        (USER, CHAT, "d", 4, payload),
        (USER, CHAT, "e", 5, payload),
    ]);

    let page = store
        .page_before(
            USER,
            CHAT,
            Some(VibeStoreCursor {
                ts_ms: 4,
                message_id: "d".into(),
            }),
            2,
        )
        .unwrap();
    // Immediately preceding d: b,c — returned ascending, not reversed.
    assert_eq!(ids(&page), ["b", "c"]);
    assert_ascending(&page);
}

#[test]
fn same_ts_cursor_does_not_drop_sibling_rows() {
    let payload = b"x";
    let (_tmp, store) = seeded(&[
        (USER, CHAT, "a", 100, payload),
        (USER, CHAT, "b", 100, payload),
        (USER, CHAT, "c", 100, payload),
    ]);

    // After "a" at ts=100 should yield b, then c — ts-only would be wrong.
    let page = store
        .page_after(
            USER,
            CHAT,
            Some(VibeStoreCursor {
                ts_ms: 100,
                message_id: "a".into(),
            }),
            10,
        )
        .unwrap();
    assert_eq!(ids(&page), ["b", "c"]);

    let page = store
        .page_before(
            USER,
            CHAT,
            Some(VibeStoreCursor {
                ts_ms: 100,
                message_id: "c".into(),
            }),
            10,
        )
        .unwrap();
    assert_eq!(ids(&page), ["a", "b"]);
}

// ---------------------------------------------------------------------------
// Limit clamp
// ---------------------------------------------------------------------------

#[test]
fn limit_is_respected_and_clamped() {
    let payload: &[u8] = b"x";
    let id_storage: Vec<String> = (0..50).map(|i| format!("m{i:03}")).collect();
    let seed: Vec<(&str, &str, &str, i64, &[u8])> = id_storage
        .iter()
        .enumerate()
        .map(|(i, id)| (USER, CHAT, id.as_str(), i as i64, payload))
        .collect();
    let (_tmp, store) = seeded(&seed);

    let page = store.page_after(USER, CHAT, None, 7).unwrap();
    assert_eq!(page.len(), 7);

    let page = store.page_before(USER, CHAT, None, 5).unwrap();
    assert_eq!(page.len(), 5);

    // Over the ceiling → clamped to MAX_PAGE_LIMIT, but we only have 50 rows.
    let page = store
        .page_after(USER, CHAT, None, MAX_PAGE_LIMIT + 500)
        .unwrap();
    assert_eq!(page.len(), 50);

    // Zero limit → empty, not an error.
    let page = store.page_after(USER, CHAT, None, 0).unwrap();
    assert!(page.is_empty());
    let page = store.page_before(USER, CHAT, None, 0).unwrap();
    assert!(page.is_empty());
}

// ---------------------------------------------------------------------------
// Empty vs missing chat
// ---------------------------------------------------------------------------

#[test]
fn empty_chat_returns_empty_vec_not_error() {
    // DB exists and has schema, but this chat has no rows.
    let (_tmp, store) = seeded(&[(USER, OTHER_CHAT, "only-other", 1, b"x")]);

    let page = store.page_after(USER, CHAT, None, 10).unwrap();
    assert!(page.is_empty());
    let page = store.page_before(USER, CHAT, None, 10).unwrap();
    assert!(page.is_empty());
    assert_eq!(store.count(USER, CHAT).unwrap(), 0);
}

#[test]
fn missing_chat_is_distinguishable_from_known_nonempty() {
    // "Missing" chat: zero rows, absent from chat_ids.
    // "Known" chat: present in chat_ids with count > 0; an empty *page* at the
    // head/tail boundary is still Ok([]) but count and chat_ids differ.
    let (_tmp, store) = seeded(&[
        (USER, OTHER_CHAT, "m1", 1, b"x"),
        (USER, OTHER_CHAT, "m2", 2, b"y"),
    ]);

    let missing_count = store.count(USER, CHAT).unwrap();
    let known_count = store.count(USER, OTHER_CHAT).unwrap();
    assert_eq!(missing_count, 0);
    assert_eq!(known_count, 2);

    let chats = store.chat_ids(USER).unwrap();
    assert!(
        !chats.contains(&CHAT.to_string()),
        "missing chat must not appear"
    );
    assert!(
        chats.contains(&OTHER_CHAT.to_string()),
        "known chat must appear"
    );

    // Empty page at the start of a known chat (after the last row) is Ok([]),
    // still distinguishable via count/chat_ids.
    let last = store.page_before(USER, OTHER_CHAT, None, 1).unwrap();
    assert_eq!(last.len(), 1);
    let past_end = store
        .page_after(USER, OTHER_CHAT, Some(cursor(&last[0])), 10)
        .unwrap();
    assert!(past_end.is_empty());
    assert_eq!(store.count(USER, OTHER_CHAT).unwrap(), 2);
    assert!(store
        .chat_ids(USER)
        .unwrap()
        .contains(&OTHER_CHAT.to_string()));
}

// ---------------------------------------------------------------------------
// Payload opacity / round-trip
// ---------------------------------------------------------------------------

#[test]
fn arbitrary_payload_bytes_round_trip_identically() {
    let crazy: Vec<u8> = {
        let mut v = vec![0u8, 1, 2, 0xFF, 0xFE, b'\n', b'\0'];
        v.extend_from_slice("not-utf8:".as_bytes());
        v.extend_from_slice(&[0x80, 0x81, 0xC0, 0xFF]);
        v.extend_from_slice(&[0; 64]);
        v
    };
    let (_tmp, store) = seeded(&[(USER, CHAT, "blob-1", 42, crazy.as_slice())]);

    let page = store.page_after(USER, CHAT, None, 1).unwrap();
    assert_eq!(page.len(), 1);
    assert_eq!(page[0].payload, crazy);
    assert_eq!(page[0].ts_ms, 42);
    assert_eq!(page[0].message_id, "blob-1");

    // Debug must not dump payload bytes.
    let rendered = format!("{:?}", page[0]);
    assert!(!rendered.contains("not-utf8"));
    assert!(rendered.contains("payload_len"));
}

// ---------------------------------------------------------------------------
// Error surface has no data
// ---------------------------------------------------------------------------

#[test]
fn store_error_debug_has_no_sql_or_paths() {
    let err = VibeStoreError::QueryFailed;
    let s = format!("{err:?} {err}");
    assert!(!s.contains("SELECT"));
    assert!(!s.contains("INSERT"));
    assert!(!s.contains(std::path::MAIN_SEPARATOR));
}

#[test]
fn open_rejects_path_with_marker_without_leaking_it() {
    let marker = "NUCLEARLAUNCHCODE";
    let dir = TempDir::new().unwrap();
    let path = dir.path().join(format!("{marker}.db"));
    // Do not create the file.
    let err = VibeLegacyStore::open(Path::new(&path)).unwrap_err();
    assert_eq!(err, VibeStoreError::NotFound);
    let rendered = format!("{err} {err:?}");
    assert!(
        !rendered.contains(marker),
        "error leaked path fragment: {rendered}"
    );
}

// ---------------------------------------------------------------------------
// chat_ids / count basics
// ---------------------------------------------------------------------------

#[test]
fn chat_ids_lists_distinct_sorted() {
    let (_tmp, store) = seeded(&[
        (USER, "z-chat", "m", 1, b"x"),
        (USER, "a-chat", "m", 1, b"x"),
        (USER, "a-chat", "n", 2, b"y"),
        ("other-user", "solo", "m", 1, b"x"),
    ]);
    assert_eq!(store.chat_ids(USER).unwrap(), vec!["a-chat", "z-chat"]);
    assert_eq!(store.count(USER, "a-chat").unwrap(), 2);
    assert_eq!(store.count(USER, "missing").unwrap(), 0);
}

#[test]
fn store_debug_is_shape_only() {
    let (_tmp, store) = seeded(&[(USER, CHAT, "m", 1, b"x")]);
    let rendered = format!("{store:?}");
    assert_eq!(rendered, "VibeLegacyStore");
}
