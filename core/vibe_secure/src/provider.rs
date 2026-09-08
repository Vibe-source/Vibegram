//! [`VibeSecureProvider`] — the SQLite-backed [`OpenMlsProvider`] MLS group
//! state persists under, so a session survives an app relaunch.
//!
//! # Why this exists
//!
//! `OpenMlsRustCrypto::default()` — the provider every test in this crate
//! used before this file existed — bundles a crypto backend, a randomness
//! source, and an in-memory key/group store (`MemoryStorage`, a `HashMap`
//! behind a lock). That last piece is the problem: ratchet state, epoch
//! secrets, and the tree all live only in that `HashMap`, so they are gone
//! the instant the process exits. Sealing a real message under that provider
//! would make it unreadable again at the next app launch — worse than not
//! shipping MLS at all. See `docs/secure-core-architecture.md` §4, "Linkage
//! status", for the fuller account of why this was left undone deliberately.
//!
//! # Composition, not reinvention
//!
//! `OpenMlsRustCrypto` is itself just a bundle:
//!
//! ```text
//! OpenMlsRustCrypto { crypto: RustCrypto, key_store: MemoryStorage }
//! ```
//!
//! `RustCrypto` (from `openmls_rust_crypto`) serves as *both* the crypto and
//! the randomness provider — there is nothing wrong with it, nothing here
//! needs to touch it. The only piece that needs replacing is `MemoryStorage`.
//! [`VibeSecureProvider`] is the same shape with that one piece swapped:
//!
//! ```text
//! VibeSecureProvider { crypto: RustCrypto, storage: SqliteStorageProvider<..> }
//! ```
//!
//! `SqliteStorageProvider` (from `openmls_sqlite_storage`) already implements
//! `openmls_traits::storage::StorageProvider` against a `rusqlite::Connection`
//! — the exact trait `MemoryStorage` implements, just durable. This file does
//! not reimplement MLS storage; it wires an existing, purpose-built
//! implementation to an owned SQLite connection and gives it this crate's
//! error shape.
//!
//! # Codec
//!
//! `SqliteStorageProvider` is generic over how each stored value is encoded
//! to bytes (its `Codec` parameter) — the storage crate ships no default.
//! [`VibeMlsCodec`] is JSON via `serde_json`, the same choice the storage
//! crate's own test suite (`tests/proposals.rs`) makes. Every type OpenMLS
//! asks the provider to store already implements `serde::Serialize` /
//! `DeserializeOwned` (that is `openmls_traits::storage::Entity`'s own
//! supertrait bound), so this is a thin, mechanical adapter, not a codec
//! designed from scratch.
//!
//! # Fail-closed migration
//!
//! [`VibeSecureProvider::open`] runs the storage crate's schema migration
//! before returning. If that migration fails partway, this function returns
//! [`VibeSecureError::Storage`] and produces no `VibeSecureProvider` at all —
//! there is no code path that hands back a value backed by a half-migrated
//! database. A caller cannot accidentally treat a broken store as usable,
//! because a broken store never becomes a `Self`.
//!
//! # Error shape
//!
//! Same governing rule as `vibe_core_store::VibeStoreError`
//! (`core/vibe_core_store/src/error.rs`): every underlying `rusqlite` or
//! `refinery` error is collapsed to [`VibeSecureError::Storage`] and
//! discarded, never forwarded — the underlying message routinely embeds the
//! path the caller passed in, which `error.rs`'s governing rule (no variant
//! carries data) forbids.

use openmls_rust_crypto::RustCrypto;
use openmls_sqlite_storage::SqliteStorageProvider;
use openmls_traits::OpenMlsProvider;
use rusqlite::Connection;

use crate::error::VibeSecureError;

/// JSON encoding for every value `SqliteStorageProvider` persists.
///
/// `pub` only because it appears inside [`VibeSecureProvider`]'s
/// `StorageProvider` associated type, and Rust requires anything reachable
/// from a public interface to itself be `pub` (rustc `E0446`) — the
/// containing module (`mod provider;` in `lib.rs`) is not `pub`, so this
/// type has no public path a caller could actually name or construct. It is
/// not a choice callers need to see or vary; see the module doc's "Codec"
/// section for why JSON specifically.
#[derive(Default)]
pub struct VibeMlsCodec;

impl openmls_sqlite_storage::Codec for VibeMlsCodec {
    type Error = serde_json::Error;

    fn to_vec<T: serde::Serialize>(value: &T) -> Result<Vec<u8>, Self::Error> {
        serde_json::to_vec(value)
    }

    fn from_slice<T: serde::de::DeserializeOwned>(slice: &[u8]) -> Result<T, Self::Error> {
        serde_json::from_slice(slice)
    }
}

/// The concrete storage type backing [`VibeSecureProvider`]. Exposed only as
/// `VibeSecureProvider::StorageProvider` through the `OpenMlsProvider` impl —
/// nothing outside this file names `VibeMlsCodec` or constructs this directly.
type Storage = SqliteStorageProvider<VibeMlsCodec, Connection>;

/// An OpenMLS provider whose group state persists in SQLite.
///
/// Composition: [`RustCrypto`] for both crypto and randomness (unchanged from
/// `OpenMlsRustCrypto`), [`SqliteStorageProvider`] for storage (the piece that
/// changed). See the module doc for why this split, not a rewrite, is the
/// right amount of change.
///
/// Deliberately not `Debug`, not `Clone`: this owns the live connection to
/// every signature key and group secret this device holds. Nothing here
/// makes that state printable or duplicable by accident — the same posture
/// [`crate::VibeSecureSession`] and [`crate::VibeDeviceIdentity`] hold for the
/// same reason.
pub struct VibeSecureProvider {
    crypto: RustCrypto,
    storage: Storage,
}

impl VibeSecureProvider {
    /// Opens (creating if absent) the MLS state database at `path`, running
    /// its schema migration before returning.
    ///
    /// Fails closed: any error opening the file or applying the migration —
    /// a missing parent directory, a permissions failure, a corrupt or
    /// partially-migrated database — returns [`VibeSecureError::Storage`]
    /// and produces no value. There is no route to a `Self` backed by a
    /// database this call was not able to fully prepare.
    pub fn open(path: &str) -> Result<Self, VibeSecureError> {
        let conn = Connection::open(path).map_err(|_| VibeSecureError::Storage)?;
        // A brief lock from another handle to the same file (e.g. a prior
        // connection not yet dropped) fails closed rather than surfacing as
        // an immediate `SQLITE_BUSY` — matches `VibeCoreStore::open`.
        conn.busy_timeout(std::time::Duration::from_millis(2000))
            .map_err(|_| VibeSecureError::Storage)?;
        Self::from_connection(conn)
    }

    /// An in-memory MLS state database, for tests only.
    ///
    /// This exists so the rest of the test suite (and any future one) can
    /// exercise [`VibeSecureProvider`]'s `OpenMlsProvider` behaviour without
    /// touching a filesystem. It is not a smaller version of [`Self::open`]
    /// with a convenient default — it recreates exactly the failure mode
    /// this crate exists to fix (group state gone the moment this value is
    /// dropped), so production code must never reach for it. `tests/
    /// persistence.rs` proves the file-backed path with [`Self::open`]
    /// instead, precisely because this constructor cannot.
    pub fn in_memory() -> Result<Self, VibeSecureError> {
        let conn = Connection::open_in_memory().map_err(|_| VibeSecureError::Storage)?;
        Self::from_connection(conn)
    }

    fn from_connection(conn: Connection) -> Result<Self, VibeSecureError> {
        let mut storage = SqliteStorageProvider::<VibeMlsCodec, Connection>::new(conn);
        storage
            .run_migrations()
            .map_err(|_| VibeSecureError::Storage)?;
        Ok(Self {
            crypto: RustCrypto::default(),
            storage,
        })
    }
}

impl OpenMlsProvider for VibeSecureProvider {
    type CryptoProvider = RustCrypto;
    type RandProvider = RustCrypto;
    type StorageProvider = Storage;

    fn storage(&self) -> &Self::StorageProvider {
        &self.storage
    }

    fn crypto(&self) -> &Self::CryptoProvider {
        &self.crypto
    }

    fn rand(&self) -> &Self::RandProvider {
        &self.crypto
    }
}
