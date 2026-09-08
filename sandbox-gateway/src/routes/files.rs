//! File read/write/tree routes.

use std::sync::Arc;

use axum::extract::{Path, Query, State};
use axum::response::Json;

use crate::error::GatewayError;
use crate::models::{
    FileQuery, ReadFileResponse, TreeQuery, TreeResponse, WriteFileRequest, WriteFileResponse,
};
use crate::runtime::files;
use crate::state::AppState;

pub async fn write(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<WriteFileRequest>,
) -> Result<Json<WriteFileResponse>, GatewayError> {
    files::write_file(&state, &id, req).await.map(Json)
}

pub async fn read(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Query(q): Query<FileQuery>,
) -> Result<Json<ReadFileResponse>, GatewayError> {
    files::read_file(&state, &id, &q.path).await.map(Json)
}

pub async fn tree(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Query(q): Query<TreeQuery>,
) -> Result<Json<TreeResponse>, GatewayError> {
    files::tree(&state, &id, q.path, q.depth).await.map(Json)
}
