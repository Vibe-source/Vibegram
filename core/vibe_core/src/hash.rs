//! FNV-1a 64, used only for change detection.
//!
//! This is **not** a security primitive and is never used as one. It exists so
//! the renderer's "did this row change" decision is an integer compare instead
//! of a deep structural comparison of a message. Collisions are a rendering
//! staleness risk, not a security risk, and 64 bits over a 300-row window is far
//! past the point where that matters.

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

/// Incremental FNV-1a 64 hasher.
#[derive(Clone, Copy, Debug)]
pub struct VibeContentHasher {
    state: u64,
}

impl Default for VibeContentHasher {
    fn default() -> Self {
        Self::new()
    }
}

impl VibeContentHasher {
    pub fn new() -> Self {
        Self { state: FNV_OFFSET }
    }

    pub fn write(&mut self, bytes: &[u8]) {
        for b in bytes {
            self.state ^= u64::from(*b);
            self.state = self.state.wrapping_mul(FNV_PRIME);
        }
    }

    /// Domain separator between adjacent fields, so `("ab", "c")` and
    /// `("a", "bc")` do not collide.
    pub fn write_sep(&mut self, tag: u8) {
        self.state ^= u64::from(tag);
        self.state = self.state.wrapping_mul(FNV_PRIME);
    }

    pub fn write_str(&mut self, value: &str) {
        self.write(value.as_bytes());
        self.write_sep(0x1f);
    }

    pub fn write_opt_str(&mut self, value: Option<&str>) {
        match value {
            Some(v) => self.write_str(v),
            None => self.write_sep(0x1e),
        }
    }

    pub fn write_u64(&mut self, value: u64) {
        self.write(&value.to_le_bytes());
        self.write_sep(0x1f);
    }

    pub fn write_i64(&mut self, value: i64) {
        self.write_u64(value as u64);
    }

    pub fn write_u32(&mut self, value: u32) {
        self.write_u64(u64::from(value));
    }

    pub fn write_bool(&mut self, value: bool) {
        self.write_sep(u8::from(value));
    }

    /// f32 is hashed through its bit pattern with NaN canonicalized, so an
    /// upload fraction cannot make a row hash unstable frame to frame.
    pub fn write_opt_f32(&mut self, value: Option<f32>) {
        match value {
            Some(v) if v.is_nan() => self.write_u32(0xffff_ffff),
            Some(v) => self.write_u32(v.to_bits()),
            None => self.write_sep(0x1e),
        }
    }

    pub fn write_opt_f64(&mut self, value: Option<f64>) {
        match value {
            Some(v) if v.is_nan() => self.write_u64(u64::MAX),
            Some(v) => self.write_u64(v.to_bits()),
            None => self.write_sep(0x1e),
        }
    }

    pub fn finish(self) -> u64 {
        self.state
    }
}

/// One-shot helper.
pub fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut h = VibeContentHasher::new();
    h.write(bytes);
    h.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_answer() {
        // FNV-1a 64 of "a" and "foobar", from the reference vectors.
        assert_eq!(fnv1a64(b"a"), 0xaf63_dc4c_8601_ec8c);
        assert_eq!(fnv1a64(b"foobar"), 0x8594_4171_f739_67e8);
    }

    #[test]
    fn field_separation_prevents_shift_collision() {
        let mut a = VibeContentHasher::new();
        a.write_str("ab");
        a.write_str("c");

        let mut b = VibeContentHasher::new();
        b.write_str("a");
        b.write_str("bc");

        assert_ne!(a.finish(), b.finish());
    }
}
