//! Resumable newest-first backfill: legacy `messages` → `core_messages_v1`.
//!
//! Sealing is a test stub — the store never inspects payloads.

use std::collections::HashSet;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use rusqlite::Connection;
use tempfile::NamedTempFile;
use vibe_core_store::{
    VibeBackfillProgress, VibeCoreStore, VibeLegacyStore, VibeRowSealer, VibeSealedRow,
    MAX_PAGE_LIMIT,
};

const USER: &str = "user-a";
const CHAT: &str = "chat-1";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

fn create_legacy_schema(conn: &Connection) {
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
    .expect("create legacy schema");
}

fn insert_legacy(conn: &Connection, user: &str, chat: &str, id: &str, ts: i64, payload: &[u8]) {
    conn.execute(
        "INSERT INTO messages(user_id, chat_id, message_id, ts, payload) VALUES(?1,?2,?3,?4,?5)",
        rusqlite::params![user, chat, id, ts, payload],
    )
    .expect("insert legacy");
}

/// One shared SQLite file: legacy `messages` + core tables.
fn seeded(rows: &[(&str, i64, &[u8])]) -> (NamedTempFile, VibeLegacyStore, VibeCoreStore) {
    let tmp = NamedTempFile::new().expect("tempfile");
    {
        let conn = Connection::open(tmp.path()).expect("write open");
        create_legacy_schema(&conn);
        for (id, ts, payload) in rows {
            insert_legacy(&conn, USER, CHAT, id, *ts, payload);
        }
    }
    let core = VibeCoreStore::open(tmp.path()).expect("open core");
    let legacy = VibeLegacyStore::open(tmp.path()).expect("open legacy");
    (tmp, legacy, core)
}

/// Sealer that returns opaque `(payload, id-bytes)` — no real crypto.
struct PassthroughSealer;

impl VibeRowSealer for PassthroughSealer {
    fn seal(
        &self,
        _user_id: &str,
        _chat_id: &str,
        message_id: &str,
        payload: &[u8],
    ) -> Option<(Vec<u8>, Vec<u8>)> {
        Some((payload.to_vec(), message_id.as_bytes().to_vec()))
    }
}

/// Sealer that always skips.
struct SkipAllSealer;

impl VibeRowSealer for SkipAllSealer {
    fn seal(
        &self,
        _user_id: &str,
        _chat_id: &str,
        _message_id: &str,
        _payload: &[u8],
    ) -> Option<(Vec<u8>, Vec<u8>)> {
        None
    }
}

/// Sealer that skips a fixed set of message ids (by id, not by payload content).
struct SkipIdsSealer {
    skip: HashSet<&'static str>,
}

impl VibeRowSealer for SkipIdsSealer {
    fn seal(
        &self,
        _user_id: &str,
        _chat_id: &str,
        message_id: &str,
        payload: &[u8],
    ) -> Option<(Vec<u8>, Vec<u8>)> {
        if self.skip.contains(message_id) {
            None
        } else {
            Some((payload.to_vec(), message_id.as_bytes().to_vec()))
        }
    }
}

/// Counts seal invocations without looking at payload bytes.
struct CountingSealer {
    calls: Arc<AtomicUsize>,
}

impl VibeRowSealer for CountingSealer {
    fn seal(
        &self,
        _user_id: &str,
        _chat_id: &str,
        message_id: &str,
        payload: &[u8],
    ) -> Option<(Vec<u8>, Vec<u8>)> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Some((payload.to_vec(), message_id.as_bytes().to_vec()))
    }
}

fn sealed_ids(store: &VibeCoreStore) -> Vec<String> {
    store
        .page_after(USER, CHAT, None, MAX_PAGE_LIMIT)
        .unwrap()
        .into_iter()
        .map(|r| r.message_id)
        .collect()
}

fn run_until_done(
    core: &VibeCoreStore,
    legacy: &VibeLegacyStore,
    sealer: &dyn VibeRowSealer,
    batch_limit: u32,
) -> VibeBackfillProgress {
    let mut total = VibeBackfillProgress {
        scanned: 0,
        written: 0,
        skipped: 0,
        done: false,
    };
    loop {
        let p = core
            .backfill_batch(legacy, USER, CHAT, sealer, batch_limit)
            .unwrap();
        total.scanned += p.scanned;
        total.written += p.written;
        total.skipped += p.skipped;
        total.done = p.done;
        if p.done {
            break;
        }
    }
    total
}

// ---------------------------------------------------------------------------
// Empty / zero limit / done no-op
// ---------------------------------------------------------------------------

#[test]
fn empty_chat_completes_immediately_with_done() {
    let (_tmp, legacy, core) = seeded(&[]);
    let p = core
        .backfill_batch(&legacy, USER, CHAT, &PassthroughSealer, 50)
        .unwrap();
    assert_eq!(
        p,
        VibeBackfillProgress {
            scanned: 0,
            written: 0,
            skipped: 0,
            done: true,
        }
    );
    assert_eq!(core.count(USER, CHAT).unwrap(), 0);

    // Re-run is a no-op reporting done.
    let p2 = core
        .backfill_batch(&legacy, USER, CHAT, &PassthroughSealer, 50)
        .unwrap();
    assert!(p2.done);
    assert_eq!(p2.scanned, 0);
    assert_eq!(p2.written, 0);
}

#[test]
fn batch_limit_zero_returns_without_work() {
    let rows: Vec<(&str, i64, &[u8])> = vec![("m1", 1, b"a"), ("m2", 2, b"b")];
    let (_tmp, legacy, core) = seeded(&rows);

    let p = core
        .backfill_batch(&legacy, USER, CHAT, &PassthroughSealer, 0)
        .unwrap();
    assert_eq!(
        p,
        VibeBackfillProgress {
            scanned: 0,
            written: 0,
            skipped: 0,
            done: false,
        }
    );
    assert_eq!(core.count(USER, CHAT).unwrap(), 0);

    // Still not done — a real batch can proceed.
    let p2 = core
        .backfill_batch(&legacy, USER, CHAT, &PassthroughSealer, 10)
        .unwrap();
    assert!(p2.done);
    assert_eq!(p2.written, 2);
    assert_eq!(core.count(USER, CHAT).unwrap(), 2);
}

#[test]
fn completed_backfill_rerun_is_noop_reporting_done() {
    let tmp = NamedTempFile::new().unwrap();
    {
        let conn = Connection::open(tmp.path()).unwrap();
        create_legacy_schema(&conn);
        for i in 0..5 {
            insert_legacy(
                &conn,
                USER,
                CHAT,
                &format!("m{i}"),
                i64::from(i),
                &[i as u8],
            );
        }
    }
    let core = VibeCoreStore::open(tmp.path()).unwrap();
    let legacy = VibeLegacyStore::open(tmp.path()).unwrap();

    let first = run_until_done(&core, &legacy, &PassthroughSealer, 2);
    assert!(first.done);
    assert_eq!(first.written, 5);
    assert_eq!(core.count(USER, CHAT).unwrap(), 5);

    let again = core
        .backfill_batch(&legacy, USER, CHAT, &PassthroughSealer, 100)
        .unwrap();
    assert!(again.done);
    assert_eq!(again.scanned, 0);
    assert_eq!(again.written, 0);
    assert_eq!(again.skipped, 0);
    assert_eq!(core.count(USER, CHAT).unwrap(), 5);
}

// ---------------------------------------------------------------------------
// Resume after interruption — small batches vs one big run
// ---------------------------------------------------------------------------

#[test]
fn resume_after_interruption_yields_every_row_exactly_once() {
    let n = 17u32;

    let make = || -> (NamedTempFile, VibeLegacyStore, VibeCoreStore) {
        let t = NamedTempFile::new().unwrap();
        {
            let conn = Connection::open(t.path()).unwrap();
            create_legacy_schema(&conn);
            for i in 0..n {
                insert_legacy(
                    &conn,
                    USER,
                    CHAT,
                    &format!("id-{i:02}"),
                    i64::from(i) * 10,
                    &[i as u8, 0xAB],
                );
            }
        }
        let core = VibeCoreStore::open(t.path()).unwrap();
        let legacy = VibeLegacyStore::open(t.path()).unwrap();
        (t, legacy, core)
    };

    // --- One big run (reference) ---
    let (_t1, legacy1, core1) = make();
    let big = run_until_done(&core1, &legacy1, &PassthroughSealer, 500);
    assert!(big.done);
    assert_eq!(big.written, u64::from(n));
    assert_eq!(big.skipped, 0);
    let big_ids = sealed_ids(&core1);
    assert_eq!(big_ids.len(), n as usize);

    // --- Many small batches with process-death simulation (reopen) between ---
    let (t2, legacy2, mut core2) = make();
    let mut total_written = 0u64;
    let mut total_scanned = 0u64;
    let mut rounds = 0u32;
    loop {
        let p = core2
            .backfill_batch(&legacy2, USER, CHAT, &PassthroughSealer, 3)
            .unwrap();
        total_written += p.written;
        total_scanned += p.scanned;
        rounds += 1;
        if p.done {
            break;
        }
        // Simulate process death: drop + reopen; cursor lives in core_meta_v1.
        drop(core2);
        core2 = VibeCoreStore::open(t2.path()).unwrap();
    }

    assert!(
        rounds > 1,
        "expected multiple batches for limit=3 over {n} rows"
    );
    assert_eq!(total_written, u64::from(n));
    assert_eq!(total_scanned, u64::from(n));
    assert_eq!(core2.count(USER, CHAT).unwrap(), u64::from(n));

    let small_ids = sealed_ids(&core2);
    assert_eq!(
        small_ids, big_ids,
        "small-batch resume must match one-shot set and order"
    );

    // No duplicates: set size equals len.
    let set: HashSet<&str> = small_ids.iter().map(String::as_str).collect();
    assert_eq!(set.len(), small_ids.len());
}

// ---------------------------------------------------------------------------
// Cursor never advances past an uncommitted batch
// ---------------------------------------------------------------------------

#[test]
fn cursor_never_advances_past_uncommitted_batch() {
    let tmp = NamedTempFile::new().unwrap();
    {
        let conn = Connection::open(tmp.path()).unwrap();
        create_legacy_schema(&conn);
        for i in 0..10 {
            insert_legacy(&conn, USER, CHAT, &format!("m{i:02}"), i64::from(i), b"p");
        }
    }
    let core = VibeCoreStore::open(tmp.path()).unwrap();
    let legacy = VibeLegacyStore::open(tmp.path()).unwrap();

    // First committed batch of 3 (newest: m09, m08, m07 → frontier m07).
    let p1 = core
        .backfill_batch(&legacy, USER, CHAT, &PassthroughSealer, 3)
        .unwrap();
    assert!(!p1.done);
    assert_eq!(p1.written, 3);
    assert_eq!(core.count(USER, CHAT).unwrap(), 3);
    let after_first = sealed_ids(&core);

    // Simulate kill-9 mid-batch: write ghost rows + advanced cursor, ROLLBACK.
    // Meta key matches the store's `bf\x1f{user}\x1f{chat}` encoding.
    let bf_key = format!("bf\u{1f}{USER}\u{1f}{CHAT}");
    let meta_before = core.meta_get(&bf_key).unwrap();
    assert!(meta_before.is_some());

    {
        let conn = Connection::open(tmp.path()).unwrap();
        conn.execute_batch("BEGIN IMMEDIATE").unwrap();
        // Ghost sealed rows that must not land.
        for (id, ts) in [("ghost-a", 100i64), ("ghost-b", 101i64)] {
            conn.execute(
                r"
                INSERT INTO core_messages_v1(
                  user_id, chat_id, message_id, ts, order_key,
                  flags, sealed_body, seal_nonce
                ) VALUES (?1,?2,?3,?4,X'00',0,X'aa',X'bb')
                ",
                rusqlite::params![USER, CHAT, id, ts],
            )
            .unwrap();
        }
        // Cursor advanced past uncommitted work (would skip real rows if kept).
        let fake_cursor = {
            let mut v = vec![0u8]; // BF_META_CURSOR
            v.extend_from_slice(&0i64.to_be_bytes()); // ts of oldest
            v.extend_from_slice(b"m00");
            v
        };
        conn.execute(
            "INSERT INTO core_meta_v1(k, v) VALUES (?1, ?2)
             ON CONFLICT(k) DO UPDATE SET v = excluded.v",
            rusqlite::params![bf_key, fake_cursor],
        )
        .unwrap();
        conn.execute_batch("ROLLBACK").unwrap();
    }

    // After rollback: same rows, same cursor as after the first committed batch.
    // Re-open so we don't rely on a connection that saw the rolled-back state
    // through a cache (WAL readers see committed snapshots only).
    drop(core);
    let core = VibeCoreStore::open(tmp.path()).unwrap();
    assert_eq!(core.count(USER, CHAT).unwrap(), 3);
    assert_eq!(sealed_ids(&core), after_first);
    assert_eq!(core.meta_get(&bf_key).unwrap(), meta_before);

    // Resume completes without gaps or duplicates.
    let rest = run_until_done(&core, &legacy, &PassthroughSealer, 3);
    assert!(rest.done);
    assert_eq!(core.count(USER, CHAT).unwrap(), 10);
    let ids = sealed_ids(&core);
    assert_eq!(ids.len(), 10);
    let set: HashSet<&str> = ids.iter().map(String::as_str).collect();
    assert_eq!(set.len(), 10);
    for i in 0..10 {
        assert!(set.contains(format!("m{i:02}").as_str()));
    }
    assert!(!set.contains("ghost-a"));
    assert!(!set.contains("ghost-b"));
}

// ---------------------------------------------------------------------------
// Sealer None + transient ids
// ---------------------------------------------------------------------------

#[test]
fn sealer_none_skips_without_advancing_written() {
    let tmp = NamedTempFile::new().unwrap();
    {
        let conn = Connection::open(tmp.path()).unwrap();
        create_legacy_schema(&conn);
        for (id, ts) in [("keep-a", 1i64), ("skip-me", 2), ("keep-b", 3)] {
            insert_legacy(&conn, USER, CHAT, id, ts, b"body");
        }
    }
    let core = VibeCoreStore::open(tmp.path()).unwrap();
    let legacy = VibeLegacyStore::open(tmp.path()).unwrap();
    let sealer = SkipIdsSealer {
        skip: HashSet::from(["skip-me"]),
    };

    let p = core
        .backfill_batch(&legacy, USER, CHAT, &sealer, 100)
        .unwrap();
    assert!(p.done);
    assert_eq!(p.scanned, 3);
    assert_eq!(p.written, 2);
    assert_eq!(p.skipped, 1);
    assert_eq!(core.count(USER, CHAT).unwrap(), 2);
    assert_eq!(sealed_ids(&core), vec!["keep-a", "keep-b"]);
}

#[test]
fn transient_ids_are_skipped_not_written() {
    let tmp = NamedTempFile::new().unwrap();
    {
        let conn = Connection::open(tmp.path()).unwrap();
        create_legacy_schema(&conn);
        insert_legacy(&conn, USER, CHAT, "stream-1", 1, b"s");
        insert_legacy(&conn, USER, CHAT, "lan-xyz", 2, b"l");
        insert_legacy(&conn, USER, CHAT, "bridge-abc", 3, b"b");
        insert_legacy(&conn, USER, CHAT, "real-msg", 4, b"r");
        insert_legacy(&conn, USER, CHAT, "stream", 5, b"ok"); // prefix only — durable
    }
    let core = VibeCoreStore::open(tmp.path()).unwrap();
    let legacy = VibeLegacyStore::open(tmp.path()).unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let sealer = CountingSealer {
        calls: Arc::clone(&calls),
    };

    let p = core
        .backfill_batch(&legacy, USER, CHAT, &sealer, 100)
        .unwrap();
    assert!(p.done);
    assert_eq!(p.scanned, 5);
    assert_eq!(p.written, 2);
    assert_eq!(p.skipped, 3);
    // Sealer is not invoked for transient ids.
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    assert_eq!(sealed_ids(&core), vec!["real-msg", "stream"]);
}

// ---------------------------------------------------------------------------
// reset_backfill_cursor restarts from newest
// ---------------------------------------------------------------------------

#[test]
fn reset_backfill_cursor_restarts_from_newest() {
    let tmp = NamedTempFile::new().unwrap();
    {
        let conn = Connection::open(tmp.path()).unwrap();
        create_legacy_schema(&conn);
        for i in 0..6 {
            insert_legacy(
                &conn,
                USER,
                CHAT,
                &format!("r{i}"),
                i64::from(i),
                &[i as u8],
            );
        }
    }
    let core = VibeCoreStore::open(tmp.path()).unwrap();
    let legacy = VibeLegacyStore::open(tmp.path()).unwrap();

    // Partial progress: one batch of 2 newest (r5, r4).
    let p1 = core
        .backfill_batch(&legacy, USER, CHAT, &PassthroughSealer, 2)
        .unwrap();
    assert!(!p1.done);
    assert_eq!(p1.written, 2);
    assert_eq!(core.count(USER, CHAT).unwrap(), 2);

    // Reset cursor — next batch starts at newest again (idempotent upserts).
    core.reset_backfill_cursor(USER, CHAT).unwrap();
    let p2 = core
        .backfill_batch(&legacy, USER, CHAT, &PassthroughSealer, 2)
        .unwrap();
    assert!(!p2.done);
    assert_eq!(p2.written, 2);
    // Still only two durable rows (upsert of the same newest pair).
    assert_eq!(core.count(USER, CHAT).unwrap(), 2);
    assert_eq!(sealed_ids(&core), vec!["r4", "r5"]);

    // Finish without reset: continues from frontier into older rows.
    let rest = run_until_done(&core, &legacy, &PassthroughSealer, 2);
    assert!(rest.done);
    assert_eq!(core.count(USER, CHAT).unwrap(), 6);

    // Reset after complete + re-run is still a full scan but idempotent writes.
    core.reset_backfill_cursor(USER, CHAT).unwrap();
    let again = run_until_done(&core, &legacy, &PassthroughSealer, 3);
    assert!(again.done);
    assert_eq!(again.written, 6);
    assert_eq!(core.count(USER, CHAT).unwrap(), 6);
}

// ---------------------------------------------------------------------------
// Newest-first order of scanning
// ---------------------------------------------------------------------------

#[test]
fn backfill_scans_newest_first() {
    let tmp = NamedTempFile::new().unwrap();
    {
        let conn = Connection::open(tmp.path()).unwrap();
        create_legacy_schema(&conn);
        for i in 0..6 {
            insert_legacy(&conn, USER, CHAT, &format!("n{i}"), i64::from(i), b"x");
        }
    }
    let core = VibeCoreStore::open(tmp.path()).unwrap();
    let legacy = VibeLegacyStore::open(tmp.path()).unwrap();

    let p = core
        .backfill_batch(&legacy, USER, CHAT, &PassthroughSealer, 2)
        .unwrap();
    assert_eq!(p.written, 2);
    // Newest two: n5 (ts=5), n4 (ts=4).
    assert_eq!(sealed_ids(&core), vec!["n4", "n5"]);
}

// ---------------------------------------------------------------------------
// Skip-all sealer still advances cursor and completes
// ---------------------------------------------------------------------------

#[test]
fn skip_all_sealer_still_completes_with_zero_written() {
    let tmp = NamedTempFile::new().unwrap();
    {
        let conn = Connection::open(tmp.path()).unwrap();
        create_legacy_schema(&conn);
        for i in 0..4 {
            insert_legacy(&conn, USER, CHAT, &format!("s{i}"), i64::from(i), b"z");
        }
    }
    let core = VibeCoreStore::open(tmp.path()).unwrap();
    let legacy = VibeLegacyStore::open(tmp.path()).unwrap();

    let p = run_until_done(&core, &legacy, &SkipAllSealer, 2);
    assert!(p.done);
    assert_eq!(p.scanned, 4);
    assert_eq!(p.written, 0);
    assert_eq!(p.skipped, 4);
    assert_eq!(core.count(USER, CHAT).unwrap(), 0);

    // Done no-op.
    let again = core
        .backfill_batch(&legacy, USER, CHAT, &SkipAllSealer, 10)
        .unwrap();
    assert!(again.done);
    assert_eq!(again.scanned, 0);
}

// ---------------------------------------------------------------------------
// Opaque sealed bytes round-trip via sealer
// ---------------------------------------------------------------------------

#[test]
fn backfill_persists_sealer_bytes_opaque() {
    let body = vec![0u8, 0xFF, 0x80, b'\0', 1];
    let tmp = NamedTempFile::new().unwrap();
    {
        let conn = Connection::open(tmp.path()).unwrap();
        create_legacy_schema(&conn);
        insert_legacy(&conn, USER, CHAT, "opaque", 9, &body);
    }
    let core = VibeCoreStore::open(tmp.path()).unwrap();
    let legacy = VibeLegacyStore::open(tmp.path()).unwrap();
    // Limit > remaining rows so this batch both writes and marks done.
    let p = core
        .backfill_batch(&legacy, USER, CHAT, &PassthroughSealer, 10)
        .unwrap();
    assert!(p.done);
    assert_eq!(p.written, 1);

    let page: Vec<VibeSealedRow> = core.page_after(USER, CHAT, None, 1).unwrap();
    assert_eq!(page[0].message_id, "opaque");
    assert_eq!(page[0].sealed_body, body);
    assert_eq!(page[0].seal_nonce, b"opaque");
}
