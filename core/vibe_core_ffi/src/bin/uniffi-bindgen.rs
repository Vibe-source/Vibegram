//! Binding generator entry point.
//!
//! UniFFI's proc-macro mode needs a host binary to read the built library's
//! embedded metadata and emit Swift. Kept in-crate (rather than as a separate
//! tool) so the generator and the scaffolding can never drift to different
//! UniFFI versions — a mismatch there produces bindings that compile and then
//! misbehave at runtime.
fn main() {
    uniffi::uniffi_bindgen_main();
}
