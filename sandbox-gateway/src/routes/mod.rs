mod browser;
mod computer;
mod files;
mod sandboxes;

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::extract::{DefaultBodyLimit, Request, State};
use axum::middleware::Next;
use axum::response::{IntoResponse, Json, Response};
use axum::routing::{delete, get, post, put};
use axum::Router;
use tracing::Instrument;

use crate::auth::require_token;
use crate::models::HealthzResponse;
use crate::state::AppState;

pub fn build(state: Arc<AppState>) -> Router {
    let body_limit = state.cfg.max_file_bytes.saturating_mul(2).max(1_000_000);

    let authed = Router::new()
        .route(
            "/v1/sandboxes",
            post(sandboxes::create).get(sandboxes::list),
        )
        .route(
            "/v1/sandboxes/:id",
            get(sandboxes::get).delete(sandboxes::delete),
        )
        .route("/v1/sandboxes/:id/exec", post(sandboxes::exec_cmd))
        .route("/v1/sandboxes/:id/exec/log", get(sandboxes::exec_log))
        .route(
            "/v1/sandboxes/:id/files",
            put(files::write).get(files::read),
        )
        .route("/v1/sandboxes/:id/tree", get(files::tree))
        .route(
            "/v1/sandboxes/:id/browser/navigate",
            post(browser::navigate),
        )
        .route("/v1/sandboxes/:id/browser/action", post(browser::action))
        .route("/v1/sandboxes/:id/browser/read", get(browser::read_page))
        .route(
            "/v1/sandboxes/:id/browser/screenshot",
            get(browser::screenshot),
        )
        .route(
            "/v1/sandboxes/:id/computer/session",
            post(computer::open_session),
        )
        .route(
            "/v1/sandboxes/:id/computer/session/:sessionId",
            delete(computer::close_session),
        )
        .route("/v1/sandboxes/:id/computer/frame", get(computer::frame))
        .route("/v1/sandboxes/:id/computer/state", get(computer::page_state))
        .route("/v1/sandboxes/:id/computer/control", post(computer::control))
        .route("/v1/sandboxes/:id/computer/input", post(computer::input))
        .route("/v1/sandboxes/:id/stop", post(sandboxes::stop))
        .layer(axum::middleware::from_fn_with_state(
            state.clone(),
            require_token,
        ));

    Router::new()
        .route("/healthz", get(healthz))
        .merge(authed)
        .layer(DefaultBodyLimit::max(body_limit))
        .layer(axum::middleware::from_fn(request_id_middleware))
        .with_state(state)
}

async fn healthz(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    Json(HealthzResponse {
        ok: true,
        containers: state.len(),
        image: state.cfg.sandbox_image.clone(),
    })
}

/// Per-process-unique, not globally unique:
fn next_request_id() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(1);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let started_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    format!("{started_ms:x}-{n:x}")
}

async fn request_id_middleware(req: Request, next: Next) -> Response {
    let request_id = next_request_id();
    let method = req.method().clone();
    let path = req.uri().path().to_string();
    let span = tracing::info_span!("request", request_id = %request_id, %method, %path);
    async move {
        let response = next.run(req).await;
        tracing::info!(status = response.status().as_u16(), "request completed");
        response
    }
    .instrument(span)
    .await
}
