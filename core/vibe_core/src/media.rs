//! Media addressing, envelope classification, and byte validation.
//!
//! **No media bytes ever enter a snapshot.** [`crate::types::VibeMediaRef`]
//! carries an identity, a natural size, and a [`crate::types::VibeThumbHandle`];
//! the platform owns the file descriptors and the pixels. A 300-row window that
//! inlined thumbnails would copy megabytes per window build, and the
//! qualification contract asks for flat retained memory over a 30-minute soak.
//!
//! # Why the current format cannot be stream-decrypted
//!
//! Today's blob is a **single AES-GCM message over the whole file**:
//! `iv || ciphertext || tag`. The authentication tag covers everything and is
//! only verifiable at the end, so producing plaintext as bytes arrive is
//! releasing unauthenticated plaintext — the exact failure mode that makes "just
//! decrypt as it streams" wrong. There are three options and only three:
//!
//! 1. buffer the whole ciphertext, verify, expose (what ships today, and it
//!    holds the file in memory twice);
//! 2. decrypt to a temp file, verify the tag, and only then hand the URL out —
//!    bounded memory, no unauthenticated exposure, one extra disk write;
//! 3. change the format.
//!
//! This crate implements (1) with a hard ceiling, describes (2) as the platform
//! contract, and **specifies** (3) as [`VibeStream2Header`] without enabling it.
//! `vmed2` is a standard segmented-AEAD construction (an AES-GCM-HKDF streaming
//! layout of the kind Tink standardised), not a bespoke scheme, and sealing is
//! deliberately unimplemented here — see [`VibeMediaError::Stream2SealNotEnabled`].

use crate::crypto::VibeAeadProvider;
use crate::error::VibeCryptoError;
use crate::secret::{VibeNonce, VibePlaintext, VibeSecretKey, VIBE_NONCE_LEN, VIBE_TAG_LEN};

/// Longest low-frequency placeholder string accepted on a thumb handle.
pub const MAX_PLACEHOLDER_LEN: usize = 64;

/// Hard ceiling for the buffer-then-verify path. Above this the platform must
/// use the decrypt-to-temp-file path, or refuse the file.
pub const MAX_WHOLE_FILE_DECRYPT_BYTES: usize = 64 * 1024 * 1024;

/// Shortest response this crate will accept as real media.
///
/// An 84-byte JSON error page cached as an `.m4a` is the poisoned-cache bug:
/// every subsequent play fails with an unsupported-file-type error, forever,
/// because the cache never re-fetches. Length plus magic bytes is the fix.
pub const MIN_MEDIA_BYTES: usize = 256;

/// Prefix of the specified-but-not-enabled streaming media format.
pub const VIBE_STREAM2_MAGIC: &[u8; 5] = b"vmed2";

/// Media validation and envelope failures.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VibeMediaError {
    /// Fewer bytes than any real asset. Almost always an error page.
    TooShort {
        minimum: usize,
        actual: usize,
    },
    /// Bytes do not match the declared type's magic number.
    MagicMismatch,
    /// Blob shorter than `iv || tag`.
    EnvelopeTruncated,
    /// Above [`MAX_WHOLE_FILE_DECRYPT_BYTES`]; the caller must stream to disk.
    TooLargeForWholeFileDecrypt {
        limit: usize,
        actual: usize,
    },
    /// `vmed2` header did not parse.
    Stream2HeaderInvalid,
    /// `vmed2` sealing is specified but intentionally not implemented here.
    Stream2SealNotEnabled,
    Crypto(VibeCryptoError),
}

impl std::fmt::Display for VibeMediaError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::TooShort { minimum, actual } => {
                write!(f, "media too short: minimum {minimum}, got {actual}")
            }
            Self::MagicMismatch => f.write_str("media bytes do not match declared type"),
            Self::EnvelopeTruncated => f.write_str("media envelope truncated"),
            Self::TooLargeForWholeFileDecrypt { limit, actual } => write!(
                f,
                "media too large for whole-file decrypt: limit {limit}, got {actual}"
            ),
            Self::Stream2HeaderInvalid => f.write_str("vmed2 header invalid"),
            Self::Stream2SealNotEnabled => f.write_str("vmed2 sealing not enabled in this build"),
            Self::Crypto(e) => write!(f, "media crypto: {e}"),
        }
    }
}

impl std::error::Error for VibeMediaError {}

impl From<VibeCryptoError> for VibeMediaError {
    fn from(value: VibeCryptoError) -> Self {
        Self::Crypto(value)
    }
}

// ---------------------------------------------------------------------------
// Addressing
// ---------------------------------------------------------------------------

/// Stable address of one remote asset, ported from `chatStableRemoteMediaIdentity`.
///
/// Query and fragment are dropped, so a re-signed URL keeps the same address.
/// Getting this wrong is not a cosmetic bug: every adopt-on-miss path silently
/// misses and the user's whole media library re-downloads.
pub fn stable_remote_media_identity(raw_url: &str) -> String {
    let url = raw_url.trim();
    if let Some(id) = backend_music_stream_id(url) {
        return format!("musicstream:{id}");
    }
    let Some(parts) = split_url(url) else {
        return url.to_string();
    };
    let host = parts.host.to_ascii_lowercase();
    if !host.is_empty() {
        return format!("{host}{}", parts.path);
    }
    format!("{}{}", parts.scheme_and_sep, parts.path)
}

/// Full cache identity: the stable address, plus the media key when the asset is
/// encrypted (two chats can share a URL and not a key).
pub fn media_identity(raw_url: &str, media_key: Option<&str>) -> String {
    let trimmed = raw_url.trim();
    let base = if has_scheme(trimmed) {
        stable_remote_media_identity(trimmed)
    } else {
        // A bare local path or synthetic key is already stable; use it verbatim.
        trimmed.to_string()
    };
    match media_key.map(str::trim).filter(|k| !k.is_empty()) {
        Some(key) => format!("{base}|k:{key}"),
        None => base,
    }
}

struct UrlParts<'a> {
    scheme_and_sep: &'a str,
    host: &'a str,
    path: &'a str,
}

fn has_scheme(url: &str) -> bool {
    match url.find("://") {
        Some(i) if i > 0 => url[..i]
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'-' || b == b'.'),
        _ => false,
    }
}

fn split_url(url: &str) -> Option<UrlParts<'_>> {
    let sep = url.find("://")?;
    if sep == 0 {
        return None;
    }
    let scheme_and_sep = &url[..sep + 3];
    let rest = &url[sep + 3..];
    let rest = rest.split(['#']).next().unwrap_or(rest);
    let rest = rest.split(['?']).next().unwrap_or(rest);
    let (authority, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, ""),
    };
    // Strip userinfo and port: neither is part of the stable address.
    let authority = authority.rsplit('@').next().unwrap_or(authority);
    let host = authority.split(':').next().unwrap_or(authority);
    Some(UrlParts {
        scheme_and_sep,
        host,
        path,
    })
}

/// `https://…vibegram.io/api/music/stream/<id>` → `<id>`.
///
/// A backend stream URL is re-signed on every resolve, so the id is the only
/// stable part. This mirrors `ChatMusicStreamResolver.videoId(fromBackendStreamURL:)`.
fn backend_music_stream_id(url: &str) -> Option<&str> {
    let parts = split_url(url)?;
    let host = parts.host;
    let host_matches = host.eq_ignore_ascii_case("vibegram.io")
        || host.to_ascii_lowercase().ends_with(".vibegram.io");
    if !host_matches {
        return None;
    }
    let mut segments = parts.path.split('/').filter(|s| !s.is_empty());
    if segments.next()? != "api" || segments.next()? != "music" || segments.next()? != "stream" {
        return None;
    }
    let id = segments.next()?.trim();
    if id.is_empty() {
        None
    } else {
        Some(id)
    }
}

// ---------------------------------------------------------------------------
// Byte validation
// ---------------------------------------------------------------------------

/// Broad asset class, derived from the declared MIME type.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VibeMediaClass {
    Jpeg,
    Png,
    Gif,
    Webp,
    Mp4,
    Mp3,
    M4a,
    Ogg,
    Wav,
    Pdf,
    /// Nothing to check beyond length.
    Unknown,
}

impl VibeMediaClass {
    pub fn from_mime(mime: &str) -> Self {
        match mime.trim().to_ascii_lowercase().as_str() {
            "image/jpeg" | "image/jpg" => Self::Jpeg,
            "image/png" => Self::Png,
            "image/gif" => Self::Gif,
            "image/webp" => Self::Webp,
            "video/mp4" | "video/quicktime" => Self::Mp4,
            "audio/mpeg" | "audio/mp3" => Self::Mp3,
            "audio/mp4" | "audio/m4a" | "audio/x-m4a" => Self::M4a,
            "audio/ogg" | "application/ogg" => Self::Ogg,
            "audio/wav" | "audio/x-wav" => Self::Wav,
            "application/pdf" => Self::Pdf,
            _ => Self::Unknown,
        }
    }

    fn matches(self, bytes: &[u8]) -> bool {
        fn starts(b: &[u8], magic: &[u8]) -> bool {
            b.len() >= magic.len() && &b[..magic.len()] == magic
        }
        fn box_type_at_4(b: &[u8], types: &[&[u8]]) -> bool {
            b.len() >= 12 && types.iter().any(|t| &b[4..8] == *t)
        }
        match self {
            Self::Jpeg => starts(bytes, &[0xFF, 0xD8, 0xFF]),
            Self::Png => starts(bytes, &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]),
            Self::Gif => starts(bytes, b"GIF87a") || starts(bytes, b"GIF89a"),
            Self::Webp => starts(bytes, b"RIFF") && bytes.len() >= 12 && &bytes[8..12] == b"WEBP",
            Self::Mp4 | Self::M4a => box_type_at_4(bytes, &[b"ftyp"]),
            // ID3-tagged or a bare MPEG frame sync.
            Self::Mp3 => {
                starts(bytes, b"ID3")
                    || (bytes.len() >= 2 && bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0)
            }
            Self::Ogg => starts(bytes, b"OggS"),
            Self::Wav => starts(bytes, b"RIFF") && bytes.len() >= 12 && &bytes[8..12] == b"WAVE",
            Self::Pdf => starts(bytes, b"%PDF-"),
            Self::Unknown => true,
        }
    }
}

/// Rejects an obviously-wrong download before it is written to the cache.
///
/// This is the single fix for the poisoned-cache class of bug. It runs on
/// *plaintext* bytes, after any envelope has been opened.
pub fn validate_media_bytes(class: VibeMediaClass, bytes: &[u8]) -> Result<(), VibeMediaError> {
    if bytes.len() < MIN_MEDIA_BYTES {
        return Err(VibeMediaError::TooShort {
            minimum: MIN_MEDIA_BYTES,
            actual: bytes.len(),
        });
    }
    if !class.matches(bytes) {
        return Err(VibeMediaError::MagicMismatch);
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Gcm1 — today's format, decode-only compatibility
// ---------------------------------------------------------------------------

/// Splits `iv || ciphertext || tag` without copying the ciphertext.
pub fn split_gcm1(blob: &[u8]) -> Result<(VibeNonce, &[u8]), VibeMediaError> {
    if blob.len() < VIBE_NONCE_LEN + VIBE_TAG_LEN {
        return Err(VibeMediaError::EnvelopeTruncated);
    }
    let nonce = VibeNonce::from_slice(&blob[..VIBE_NONCE_LEN])
        .map_err(|_| VibeMediaError::EnvelopeTruncated)?;
    Ok((nonce, &blob[VIBE_NONCE_LEN..]))
}

/// Opens a whole-file `Gcm1` blob.
///
/// Buffers, verifies, then returns. There is no partial-output variant on
/// purpose: a partial output would be unauthenticated plaintext. Callers with a
/// file larger than [`MAX_WHOLE_FILE_DECRYPT_BYTES`] must use the platform's
/// decrypt-to-temp-file path and only publish the URL after the tag verifies.
pub fn open_gcm1(
    provider: &dyn VibeAeadProvider,
    key: &VibeSecretKey,
    blob: &[u8],
) -> Result<VibePlaintext, VibeMediaError> {
    if blob.len() > MAX_WHOLE_FILE_DECRYPT_BYTES {
        return Err(VibeMediaError::TooLargeForWholeFileDecrypt {
            limit: MAX_WHOLE_FILE_DECRYPT_BYTES,
            actual: blob.len(),
        });
    }
    let (nonce, ciphertext_and_tag) = split_gcm1(blob)?;
    // AAD is empty for wire compatibility with every deployed client.
    provider
        .open(key, &nonce, b"", ciphertext_and_tag)
        .map_err(VibeMediaError::from)
}

/// Seals a whole-file `Gcm1` blob. Used only by fixtures and by the
/// re-encryption path; production uploads keep using the platform implementation
/// until the FFI lands.
pub fn seal_gcm1(
    provider: &dyn VibeAeadProvider,
    key: &VibeSecretKey,
    plaintext: &[u8],
) -> Result<Vec<u8>, VibeMediaError> {
    let nonce = VibeNonce::random()?;
    let mut out = Vec::with_capacity(VIBE_NONCE_LEN + plaintext.len() + VIBE_TAG_LEN);
    out.extend_from_slice(nonce.as_bytes());
    out.extend_from_slice(&provider.seal(key, &nonce, b"", plaintext)?);
    Ok(out)
}

// ---------------------------------------------------------------------------
// Stream2 — specified, parseable, not enabled
// ---------------------------------------------------------------------------

/// Header of the future segmented media format.
///
/// ```text
/// "vmed2" || version:u8 || salt[16] || segment_len:u32 LE || segment*
/// segment_i = AEAD(key_i = HKDF(master, salt), nonce = prefix || i || last_flag)
/// ```
///
/// Detection is by prefix, so no message metadata changes and old `Gcm1` blobs
/// stay readable forever. **Parsing is implemented so a client can recognise and
/// refuse a `vmed2` blob it cannot open; sealing is not implemented in this
/// crate.** Enabling it is a separate program with its own rollout — see the
/// production doc, § "Media v1/v2 compatibility".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VibeStream2Header {
    pub version: u8,
    pub salt: [u8; 16],
    pub segment_len: u32,
    /// Byte offset where the first segment starts.
    pub body_offset: usize,
}

/// Header size: magic + version + salt + segment length.
pub const VIBE_STREAM2_HEADER_LEN: usize = 5 + 1 + 16 + 4;

/// True when a blob claims the `vmed2` format.
pub fn is_stream2(blob: &[u8]) -> bool {
    blob.len() >= VIBE_STREAM2_MAGIC.len()
        && &blob[..VIBE_STREAM2_MAGIC.len()] == VIBE_STREAM2_MAGIC
}

/// Parses a `vmed2` header. Never decrypts.
pub fn parse_stream2_header(blob: &[u8]) -> Result<VibeStream2Header, VibeMediaError> {
    if !is_stream2(blob) || blob.len() < VIBE_STREAM2_HEADER_LEN {
        return Err(VibeMediaError::Stream2HeaderInvalid);
    }
    let version = blob[5];
    if version != 1 {
        return Err(VibeMediaError::Stream2HeaderInvalid);
    }
    let mut salt = [0u8; 16];
    salt.copy_from_slice(&blob[6..22]);
    let segment_len = u32::from_le_bytes([blob[22], blob[23], blob[24], blob[25]]);
    // A zero or absurd segment length is a malformed header, not a decrypt hint.
    if segment_len == 0 || segment_len > 8 * 1024 * 1024 {
        return Err(VibeMediaError::Stream2HeaderInvalid);
    }
    Ok(VibeStream2Header {
        version,
        salt,
        segment_len,
        body_offset: VIBE_STREAM2_HEADER_LEN,
    })
}

/// Always fails. Present so the deferral is a compile-time visible fact rather
/// than a paragraph in a document.
pub fn seal_stream2(_plaintext: &[u8]) -> Result<Vec<u8>, VibeMediaError> {
    Err(VibeMediaError::Stream2SealNotEnabled)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_survives_url_resigning() {
        let a = media_identity(
            "https://cdn.vibegram.io/media/abc.jpg?sig=aaa&exp=1",
            Some("k1"),
        );
        let b = media_identity(
            "https://cdn.vibegram.io/media/abc.jpg?sig=bbb&exp=2",
            Some("k1"),
        );
        assert_eq!(a, b);
        assert_eq!(a, "cdn.vibegram.io/media/abc.jpg|k:k1");
    }

    #[test]
    fn identity_separates_by_media_key() {
        let a = media_identity("https://cdn.vibegram.io/m/1.jpg", Some("k1"));
        let b = media_identity("https://cdn.vibegram.io/m/1.jpg", Some("k2"));
        let plain = media_identity("https://cdn.vibegram.io/m/1.jpg", None);
        assert_ne!(a, b);
        assert_ne!(a, plain);
        assert_eq!(plain, "cdn.vibegram.io/m/1.jpg");
    }

    #[test]
    fn music_stream_urls_collapse_to_the_track_id() {
        assert_eq!(
            media_identity(
                "https://vibegram.io/api/music/stream/sc_12345?token=x",
                None
            ),
            "musicstream:sc_12345"
        );
        assert_eq!(
            media_identity("https://api.vibegram.io/api/music/stream/yt_abc", None),
            "musicstream:yt_abc"
        );
        // Not our host: ordinary path rule.
        assert_eq!(
            media_identity("https://other.example/api/music/stream/x", None),
            "other.example/api/music/stream/x"
        );
    }

    #[test]
    fn host_case_and_port_do_not_change_the_address() {
        assert_eq!(
            media_identity("https://CDN.Vibegram.io:443/m/1.jpg", None),
            "cdn.vibegram.io/m/1.jpg"
        );
    }

    #[test]
    fn local_paths_are_used_verbatim() {
        assert_eq!(
            media_identity("/var/mobile/x.m4a", None),
            "/var/mobile/x.m4a"
        );
        assert_eq!(
            media_identity("synthetic-key-42", Some("k")),
            "synthetic-key-42|k:k"
        );
    }

    #[test]
    fn an_error_page_is_never_accepted_as_audio() {
        let error_page = br#"{"error":"Missing SoundCloud source URL in cache"}"#;
        assert_eq!(
            validate_media_bytes(VibeMediaClass::M4a, error_page).unwrap_err(),
            VibeMediaError::TooShort {
                minimum: MIN_MEDIA_BYTES,
                actual: error_page.len()
            }
        );

        // Long enough, still not m4a.
        let mut long_html = b"<!DOCTYPE html>".to_vec();
        long_html.resize(1024, b' ');
        assert_eq!(
            validate_media_bytes(VibeMediaClass::M4a, &long_html).unwrap_err(),
            VibeMediaError::MagicMismatch
        );
    }

    #[test]
    fn real_magic_numbers_pass() {
        let mut jpeg = vec![0xFF, 0xD8, 0xFF, 0xE0];
        jpeg.resize(1024, 0);
        assert!(validate_media_bytes(VibeMediaClass::Jpeg, &jpeg).is_ok());

        let mut m4a = vec![
            0, 0, 0, 0x20, b'f', b't', b'y', b'p', b'M', b'4', b'A', b' ',
        ];
        m4a.resize(1024, 0);
        assert!(validate_media_bytes(VibeMediaClass::M4a, &m4a).is_ok());

        let mut unknown = vec![0u8; 512];
        unknown[0] = 0x42;
        assert!(validate_media_bytes(VibeMediaClass::Unknown, &unknown).is_ok());
    }

    #[test]
    fn gcm1_split_rejects_a_truncated_blob() {
        assert_eq!(
            split_gcm1(&[0u8; 20]).unwrap_err(),
            VibeMediaError::EnvelopeTruncated
        );
        let (nonce, rest) = split_gcm1(&[7u8; 60]).unwrap();
        assert_eq!(nonce.as_bytes(), &[7u8; 12]);
        assert_eq!(rest.len(), 48);
    }

    #[test]
    fn stream2_parses_and_refuses_to_seal() {
        let mut blob = Vec::new();
        blob.extend_from_slice(VIBE_STREAM2_MAGIC);
        blob.push(1);
        blob.extend_from_slice(&[9u8; 16]);
        blob.extend_from_slice(&(65536u32).to_le_bytes());
        blob.extend_from_slice(&[0u8; 32]);

        let h = parse_stream2_header(&blob).unwrap();
        assert_eq!(h.version, 1);
        assert_eq!(h.segment_len, 65536);
        assert_eq!(h.body_offset, VIBE_STREAM2_HEADER_LEN);

        assert_eq!(
            seal_stream2(b"anything").unwrap_err(),
            VibeMediaError::Stream2SealNotEnabled
        );
        assert!(!is_stream2(b"not vmed2 at all"));
    }

    #[test]
    fn stream2_rejects_a_zero_segment_length() {
        let mut blob = Vec::new();
        blob.extend_from_slice(VIBE_STREAM2_MAGIC);
        blob.push(1);
        blob.extend_from_slice(&[0u8; 16]);
        blob.extend_from_slice(&0u32.to_le_bytes());
        assert_eq!(
            parse_stream2_header(&blob).unwrap_err(),
            VibeMediaError::Stream2HeaderInvalid
        );
    }

    #[cfg(feature = "aead-aes-gcm")]
    #[test]
    fn gcm1_round_trip_and_tamper_detection() {
        use crate::crypto::VibeAesGcm256Aead;

        let provider = VibeAesGcm256Aead;
        let key = VibeSecretKey::from_bytes([3u8; 32]);
        let mut plaintext = vec![0xFF, 0xD8, 0xFF, 0xE0];
        plaintext.resize(4096, 0x5A);

        let blob = seal_gcm1(&provider, &key, &plaintext).unwrap();
        let opened = open_gcm1(&provider, &key, &blob).unwrap();
        assert_eq!(opened.as_bytes(), &plaintext[..]);
        assert!(validate_media_bytes(VibeMediaClass::Jpeg, opened.as_bytes()).is_ok());

        let mut tampered = blob.clone();
        tampered[VIBE_NONCE_LEN + 10] ^= 0xFF;
        let Err(err) = open_gcm1(&provider, &key, &tampered) else {
            panic!("tampered ciphertext must not open");
        };
        assert_eq!(
            err,
            VibeMediaError::Crypto(VibeCryptoError::AuthenticationFailed)
        );
    }
}
