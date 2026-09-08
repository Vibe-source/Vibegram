use std::sync::Arc;

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Json, Response};

use crate::error::GatewayError;
use crate::models::{
    ComputerControlRequest, ComputerControlResponse, ComputerFrameQuery, ComputerInputRequest,
    ComputerInputResponse, ComputerSessionClosedResponse, ComputerSessionRequest,
    ComputerSessionResponse, ComputerStateResponse,
};
use crate::runtime::computer;
use crate::state::AppState;

pub async fn open_session(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<ComputerSessionRequest>,
) -> Result<Json<ComputerSessionResponse>, GatewayError> {
    computer::open_session(&state, &id, &req).map(Json)
}

pub async fn close_session(
    State(state): State<Arc<AppState>>,
    Path((id, session_id)): Path<(String, String)>,
) -> Json<ComputerSessionClosedResponse> {
    computer::close_session(&state, &id, &session_id);
    Json(ComputerSessionClosedResponse {
        session_id,
        status: "closed".to_string(),
    })
}

pub async fn frame(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Query(q): Query<ComputerFrameQuery>,
) -> Result<Response, GatewayError> {
    let since = q.since.unwrap_or(0);
    match computer::frame(&state, &id, since, q.session.as_deref()).await? {
        Some(frame) => Ok(Json(frame).into_response()),
        None => Ok(StatusCode::NO_CONTENT.into_response()),
    }
}

pub async fn page_state(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Query(q): Query<ComputerFrameQuery>,
) -> Result<Json<ComputerStateResponse>, GatewayError> {
    computer::page_state(&state, &id, q.session.as_deref())
        .await
        .map(Json)
}

pub async fn control(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<ComputerControlRequest>,
) -> Result<Json<ComputerControlResponse>, GatewayError> {
    computer::control_action(&state, &id, &req.action, &req.session_id, req.ttl_seconds).map(Json)
}

pub async fn input(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(req): Json<ComputerInputRequest>,
) -> Result<Json<ComputerInputResponse>, GatewayError> {
    computer::input(&state, &id, req).await.map(Json)
}

#[cfg(test)]
mod tests {
    use axum::body::{to_bytes, Body};
    use axum::http::{Request, StatusCode};
    use bollard::Docker;
    use std::sync::Arc;
    use tower::ServiceExt;

    use crate::config::test_config;
    use crate::runtime::computer::CapturedFrame;
    use crate::runtime::now_ms;
    use crate::state::{AppState, SandboxEntry};

    const SANDBOX: &str = "vibe-sb-abc";

    fn app_state() -> Arc<AppState> {
        let cfg = test_config();
        let docker = Docker::connect_with_http_defaults().unwrap();
        let state = Arc::new(AppState::new(cfg, docker));
        state.upsert(
            SANDBOX,
            SandboxEntry {
                owner_key: "agent:1".into(),
                created_at: 0,
                last_used_at: 0,
                ttl_seconds: None,
            },
        );
        state
    }

    fn signed(state: &AppState, method: &str, uri: &str, body: &str) -> Request<Body> {
        Request::builder()
            .method(method)
            .uri(uri)
            .header("x-sandbox-token", state.cfg.gateway_token.clone())
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap()
    }

    async fn json_body(resp: axum::response::Response) -> serde_json::Value {
        let bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    async fn open(state: &Arc<AppState>, sandbox: &str, viewer: &str) -> axum::response::Response {
        let body = format!(r#"{{"viewerId":"{viewer}"}}"#);
        crate::routes::build(state.clone())
            .oneshot(signed(
                state,
                "POST",
                &format!("/v1/sandboxes/{sandbox}/computer/session"),
                &body,
            ))
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn session_route_returns_the_frozen_shape() {
        let state = app_state();
        let resp = open(&state, SANDBOX, "user:7").await;
        assert_eq!(resp.status(), StatusCode::OK);
        let v = json_body(resp).await;
        assert!(v["sessionId"].as_str().unwrap().starts_with("cs_"));
        assert_eq!(v["fps"], 3);
        assert_eq!(v["width"], 720);
        assert_eq!(v["quality"], 55);
        assert_eq!(v["control"], "agent");
        assert!(v["holder"].is_null());
        assert!(v["expiresAt"].as_i64().is_some());
    }

    #[tokio::test]
    async fn session_route_requires_the_gateway_token() {
        let state = app_state();
        let req = Request::builder()
            .method("POST")
            .uri(format!("/v1/sandboxes/{SANDBOX}/computer/session"))
            .header("content-type", "application/json")
            .body(Body::from(r#"{"viewerId":"user:7"}"#))
            .unwrap();
        let resp = crate::routes::build(state).oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn frame_route_answers_204_when_nothing_is_newer() {
        let state = app_state();
        open(&state, SANDBOX, "user:7").await;
        let stored = state.computer.store_frame(
            &state.cfg,
            SANDBOX,
            CapturedFrame {
                jpeg_base64: "aGk=".into(),
                mime: "image/jpeg".into(),
                width: 720,
                height: 405,
                url: "https://a.example/".into(),
                title: "A".into(),
                loading: false,
            },
            now_ms(),
        );

        let resp = crate::routes::build(state.clone())
            .oneshot(signed(
                &state,
                "GET",
                &format!("/v1/sandboxes/{SANDBOX}/computer/frame?since={}", stored.seq),
                "",
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::NO_CONTENT);

        let behind = crate::routes::build(state.clone())
            .oneshot(signed(
                &state,
                "GET",
                &format!("/v1/sandboxes/{SANDBOX}/computer/frame?since=0"),
                "",
            ))
            .await
            .unwrap();
        assert_eq!(behind.status(), StatusCode::OK);
        let v = json_body(behind).await;
        assert_eq!(v["seq"], stored.seq);
        assert_eq!(v["imageBase64"], "aGk=");
        assert_eq!(v["control"], "agent");
    }

    #[tokio::test]
    async fn input_route_409s_without_control_and_passes_the_gate_with_it() {
        let state = app_state();
        let session_id = json_body(open(&state, SANDBOX, "user:7").await).await["sessionId"]
            .as_str()
            .unwrap()
            .to_string();

        let body = format!(r#"{{"sessionId":"{session_id}","kind":"click","x":10,"y":20}}"#);
        let denied = crate::routes::build(state.clone())
            .oneshot(signed(
                &state,
                "POST",
                &format!("/v1/sandboxes/{SANDBOX}/computer/input"),
                &body,
            ))
            .await
            .unwrap();
        assert_eq!(denied.status(), StatusCode::CONFLICT);
        assert_eq!(json_body(denied).await["error"], "control_not_held");

        let grant = format!(r#"{{"action":"grant","sessionId":"{session_id}","ttlSeconds":60}}"#);
        let granted = crate::routes::build(state.clone())
            .oneshot(signed(
                &state,
                "POST",
                &format!("/v1/sandboxes/{SANDBOX}/computer/control"),
                &grant,
            ))
            .await
            .unwrap();
        assert_eq!(granted.status(), StatusCode::OK);
        let v = json_body(granted).await;
        assert_eq!(v["control"], "user");
        assert_eq!(v["holder"], session_id);

        assert!(state
            .computer
            .authorize_input(SANDBOX, &session_id, crate::runtime::now_unix())
            .is_ok());
    }

    #[tokio::test]
    async fn session_route_429s_past_the_live_cap() {
        let state = app_state();
        for n in 0..state.cfg.computer_max_live {
            let sandbox = format!("vibe-sb-{n}");
            state.upsert(
                &sandbox,
                SandboxEntry {
                    owner_key: format!("agent:{n}"),
                    created_at: 0,
                    last_used_at: 0,
                    ttl_seconds: None,
                },
            );
            assert_eq!(open(&state, &sandbox, "user:7").await.status(), StatusCode::OK);
        }
        let resp = open(&state, SANDBOX, "user:7").await;
        assert_eq!(resp.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(json_body(resp).await["error"], "computer_capacity");
    }

    #[tokio::test]
    async fn close_session_route_is_idempotent_and_frees_capacity() {
        let state = app_state();
        let session_id = json_body(open(&state, SANDBOX, "user:7").await).await["sessionId"]
            .as_str()
            .unwrap()
            .to_string();
        let uri = format!("/v1/sandboxes/{SANDBOX}/computer/session/{session_id}");
        for _ in 0..2 {
            let resp = crate::routes::build(state.clone())
                .oneshot(signed(&state, "DELETE", &uri, ""))
                .await
                .unwrap();
            assert_eq!(resp.status(), StatusCode::OK);
            let v = json_body(resp).await;
            assert_eq!(v["sessionId"], session_id);
            assert_eq!(v["status"], "closed");
        }
    }
}
