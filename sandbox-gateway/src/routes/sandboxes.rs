use std::sync::Arc;

use axum::extract::{Path, Query, State};
use axum::response::Json;

use crate::error::GatewayError;
use crate::models::{
    CreateSandboxRequest, ExecLogEntry, ExecLogQuery, ExecLogResponse, ExecRequest, ExecResponse,
    SandboxActionResponse, SandboxCreatedResponse, SandboxDetailResponse, SandboxListResponse,
};
use crate::runtime::{containers, exec};
use crate::state::AppState;

pub async fn create(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateSandboxRequest>,
) -> Result<Json<SandboxCreatedResponse>, GatewayError> {
    containers::ensure_sandbox(&state, req).await.map(Json)
}

pub async fn get(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<SandboxDetailResponse>, GatewayError> {
    containers::get_sandbox(&state, &id).await.map(Json)
}

pub async fn list(
    State(state): State<Arc<AppState>>,
) -> Result<Json<SandboxListResponse>, GatewayError> {
    containers::list_sandboxes(&state).await.map(Json)
}

pub async fn exec_cmd(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<ExecRequest>,
) -> Result<Json<ExecResponse>, GatewayError> {
    let cmd = req.cmd.clone();
    let cwd = req.cwd.clone();
    let started_at = now_secs();
    let result = exec::exec(&state, &id, req).await?;

    state.record_exec(
        &id,
        ExecLogEntry {
            seq: 0,
            cmd,
            cwd,
            exit_code: result.exit_code,
            stdout: result.stdout.clone(),
            stderr: result.stderr.clone(),
            truncated: result.truncated,
            duration_ms: result.duration_ms,
            started_at,
        },
    );

    Ok(Json(result))
}

/// The owner-visible terminal:
pub async fn exec_log(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Query(query): Query<ExecLogQuery>,
) -> Result<Json<ExecLogResponse>, GatewayError> {
    let entries = state.exec_log(&id, query.since.unwrap_or(0), query.limit.unwrap_or(40).min(200));
    Ok(Json(ExecLogResponse { entries }))
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

pub async fn stop(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<SandboxActionResponse>, GatewayError> {
    containers::stop_sandbox(&state, &id).await.map(Json)
}

pub async fn delete(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<SandboxActionResponse>, GatewayError> {
    containers::delete_sandbox(&state, &id).await.map(Json)
}
