use std::sync::Arc;

use axum::extract::{Request, State};
use axum::middleware::Next;
use axum::response::Response;

use crate::error::GatewayError;
use crate::state::AppState;

const TOKEN_HEADER: &str = "x-sandbox-token";

/// Constant-time byte comparison so a mismatch can't leak timing info about.
pub fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff: u8 = 0;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

pub async fn require_token(
    State(state): State<Arc<AppState>>,
    req: Request,
    next: Next,
) -> Result<Response, GatewayError> {
    let provided = req
        .headers()
        .get(TOKEN_HEADER)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if !constant_time_eq(provided.as_bytes(), state.cfg.gateway_token.as_bytes()) {
        return Err(GatewayError::Unauthorized);
    }
    Ok(next.run(req).await)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn equal_tokens_match() {
        assert!(constant_time_eq(b"abc123", b"abc123"));
    }

    #[test]
    fn different_tokens_do_not_match() {
        assert!(!constant_time_eq(b"abc123", b"abc124"));
    }

    #[test]
    fn different_length_never_matches() {
        assert!(!constant_time_eq(b"abc", b"abc123"));
        assert!(!constant_time_eq(b"", b"a"));
    }

    #[test]
    fn empty_tokens_match() {
        assert!(constant_time_eq(b"", b""));
    }

    #[test]
    fn case_sensitive() {
        assert!(!constant_time_eq(b"AbC", b"abc"));
    }
}
