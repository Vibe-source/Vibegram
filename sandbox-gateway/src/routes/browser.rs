//! Browser action routes.

use std::sync::Arc;

use axum::extract::{Path, Query, State};
use axum::response::Json;

use crate::error::GatewayError;
use crate::models::{
    BrowserActionRequest, BrowserActionResponse, BrowserNavigateRequest, BrowserNavigateResponse,
    ScreenshotQuery, ScreenshotResponse,
};
use crate::runtime::browser;
use crate::state::AppState;

const DEFAULT_MAX_WIDTH: u32 = 1024;

pub async fn navigate(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<BrowserNavigateRequest>,
) -> Result<Json<BrowserNavigateResponse>, GatewayError> {
    browser::navigate(&state, &id, &req.url).await.map(Json)
}

pub async fn action(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<BrowserActionRequest>,
) -> Result<Json<BrowserActionResponse>, GatewayError> {
    browser::action(&state, &id, req).await.map(Json)
}

pub async fn read_page(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, GatewayError> {
    browser::read_page(&state, &id).await.map(Json)
}

pub async fn screenshot(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Query(q): Query<ScreenshotQuery>,
) -> Result<Json<ScreenshotResponse>, GatewayError> {
    let max_width = q.max_width.unwrap_or(DEFAULT_MAX_WIDTH);
    browser::screenshot(&state, &id, max_width).await.map(Json)
}
