//! Request/response DTOs for the sandbox-gateway API (spec.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NetworkMode {
    None,
    Proxy,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateSandboxRequest {
    #[serde(rename = "ownerKey")]
    pub owner_key: String,
    pub image: Option<String>,
    pub cpus: Option<f64>,
    #[serde(rename = "memoryMb")]
    pub memory_mb: Option<i64>,
    #[serde(rename = "pidsLimit")]
    pub pids_limit: Option<i64>,
    pub network: NetworkMode,
    #[serde(rename = "ttlSeconds")]
    pub ttl_seconds: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SandboxCreatedResponse {
    pub id: String,
    pub status: String,
    #[serde(rename = "createdAt")]
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct SandboxDetailResponse {
    pub id: String,
    pub status: String,
    #[serde(rename = "ownerKey")]
    pub owner_key: String,
    #[serde(rename = "createdAt")]
    pub created_at: i64,
    #[serde(rename = "lastUsedAt")]
    pub last_used_at: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct SandboxListResponse {
    pub sandboxes: Vec<SandboxDetailResponse>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SandboxActionResponse {
    pub id: String,
    pub status: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ExecRequest {
    pub cmd: Vec<String>,
    pub cwd: Option<String>,
    pub env: Option<HashMap<String, String>>,
    #[serde(rename = "timeoutMs")]
    pub timeout_ms: Option<u64>,
    #[serde(rename = "maxOutputBytes")]
    pub max_output_bytes: Option<usize>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ExecResponse {
    #[serde(rename = "exitCode")]
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
    pub truncated: bool,
    #[serde(rename = "durationMs")]
    pub duration_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// One recorded shell run.
#[derive(Debug, Clone, Serialize)]
pub struct ExecLogEntry {
    pub seq: u64,
    pub cmd: Vec<String>,
    pub cwd: Option<String>,
    #[serde(rename = "exitCode")]
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
    pub truncated: bool,
    #[serde(rename = "durationMs")]
    pub duration_ms: u64,
    #[serde(rename = "startedAt")]
    pub started_at: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ExecLogResponse {
    pub entries: Vec<ExecLogEntry>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ExecLogQuery {
    pub since: Option<u64>,
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WriteFileRequest {
    pub path: String,
    #[serde(rename = "contentBase64")]
    pub content_base64: String,
    pub mode: Option<u32>,
}

#[derive(Debug, Clone, Serialize)]
pub struct WriteFileResponse {
    pub path: String,
    pub bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ReadFileResponse {
    pub path: String,
    #[serde(rename = "contentBase64")]
    pub content_base64: String,
    pub bytes: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct FileQuery {
    pub path: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TreeQuery {
    pub path: Option<String>,
    pub depth: Option<u32>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TreeEntry {
    pub path: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct TreeResponse {
    pub entries: Vec<TreeEntry>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct BrowserNavigateRequest {
    pub url: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct BrowserNavigateResponse {
    pub url: String,
    pub title: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct BrowserActionRequest {
    pub kind: String,
    pub selector: Option<String>,
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub text: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct BrowserActionResponse {
    pub ok: bool,
    pub url: String,
    pub title: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ScreenshotQuery {
    #[serde(rename = "maxWidth")]
    pub max_width: Option<u32>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ScreenshotResponse {
    #[serde(rename = "imageBase64")]
    pub image_base64: String,
    pub mime: String,
    pub width: u32,
    pub height: u32,
}

/// Who may drive the sandbox browser.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Control {
    #[default]
    Agent,
    User,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ComputerSessionRequest {
    #[serde(rename = "viewerId")]
    pub viewer_id: String,
    pub fps: Option<u32>,
    pub width: Option<u32>,
    pub quality: Option<u32>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ComputerSessionResponse {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub fps: u32,
    pub width: u32,
    pub quality: u32,
    pub control: Control,
    pub holder: Option<String>,
    #[serde(rename = "expiresAt")]
    pub expires_at: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ComputerSessionClosedResponse {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub status: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct ComputerFrameQuery {
    pub since: Option<u64>,
    pub session: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ComputerFrameResponse {
    pub seq: u64,
    #[serde(rename = "imageBase64")]
    pub image_base64: String,
    pub mime: String,
    pub width: u32,
    pub height: u32,
    pub url: String,
    pub title: String,
    pub loading: bool,
    pub control: Control,
    #[serde(rename = "capturedAt")]
    pub captured_at: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ComputerStateResponse {
    pub url: String,
    pub title: String,
    pub loading: bool,
    pub control: Control,
    pub holder: Option<String>,
    #[serde(rename = "expiresAt")]
    pub expires_at: Option<i64>,
    #[serde(rename = "tabCount")]
    pub tab_count: u32,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ComputerControlRequest {
    pub action: String,
    #[serde(rename = "sessionId")]
    pub session_id: String,
    #[serde(rename = "ttlSeconds")]
    pub ttl_seconds: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ComputerControlResponse {
    pub control: Control,
    pub holder: Option<String>,
    #[serde(rename = "expiresAt")]
    pub expires_at: Option<i64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ComputerInputRequest {
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub kind: String,
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub text: Option<String>,
    pub key: Option<String>,
    #[serde(rename = "deltaY")]
    pub delta_y: Option<f64>,
    pub url: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ComputerInputResponse {
    pub ok: bool,
    pub url: String,
    pub title: String,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct BrowserStateResponse {
    pub url: String,
    pub title: String,
    pub loading: bool,
    #[serde(rename = "tabCount")]
    pub tab_count: u32,
}

#[derive(Debug, Clone, Serialize)]
pub struct HealthzResponse {
    pub ok: bool,
    pub containers: usize,
    pub image: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ErrorResponse {
    pub error: String,
}

impl ErrorResponse {
    pub fn new(msg: impl Into<String>) -> Self {
        Self { error: msg.into() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_sandbox_request_parses_frozen_field_names() {
        let json = r#"{"ownerKey":"agent:1","image":"vibe-sandbox:latest","cpus":1.5,
            "memoryMb":2048,"pidsLimit":128,"network":"proxy","ttlSeconds":600}"#;
        let req: CreateSandboxRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.owner_key, "agent:1");
        assert_eq!(req.network, NetworkMode::Proxy);
        assert_eq!(req.ttl_seconds, Some(600));
    }

    #[test]
    fn create_sandbox_request_allows_omitted_optionals() {
        let json = r#"{"ownerKey":"agent:1","network":"none"}"#;
        let req: CreateSandboxRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.network, NetworkMode::None);
        assert!(req.image.is_none());
        assert!(req.cpus.is_none());
    }

    #[test]
    fn network_mode_serializes_lowercase() {
        assert_eq!(
            serde_json::to_string(&NetworkMode::None).unwrap(),
            "\"none\""
        );
        assert_eq!(
            serde_json::to_string(&NetworkMode::Proxy).unwrap(),
            "\"proxy\""
        );
    }

    #[test]
    fn sandbox_created_response_uses_camel_case() {
        let resp = SandboxCreatedResponse {
            id: "vibe-sb-abc".into(),
            status: "running".into(),
            created_at: 100,
        };
        let v: serde_json::Value = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["createdAt"], 100);
        assert!(v.get("created_at").is_none());
    }

    #[test]
    fn sandbox_detail_response_field_names() {
        let resp = SandboxDetailResponse {
            id: "vibe-sb-abc".into(),
            status: "running".into(),
            owner_key: "agent:1".into(),
            created_at: 100,
            last_used_at: 200,
        };
        let v: serde_json::Value = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["ownerKey"], "agent:1");
        assert_eq!(v["createdAt"], 100);
        assert_eq!(v["lastUsedAt"], 200);
    }

    #[test]
    fn exec_request_parses() {
        let json = r#"{"cmd":["ls","-la"],"cwd":"/home/agent","env":{"A":"B"},
            "timeoutMs":5000,"maxOutputBytes":1000}"#;
        let req: ExecRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.cmd, vec!["ls", "-la"]);
        assert_eq!(req.timeout_ms, Some(5000));
    }

    #[test]
    fn exec_response_omits_error_when_none() {
        let resp = ExecResponse {
            exit_code: 0,
            stdout: "hi".into(),
            stderr: "".into(),
            truncated: false,
            duration_ms: 10,
            error: None,
        };
        let v: serde_json::Value = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["exitCode"], 0);
        assert!(v.get("error").is_none());
    }

    #[test]
    fn exec_response_includes_error_on_timeout() {
        let resp = ExecResponse {
            exit_code: 124,
            stdout: "".into(),
            stderr: "".into(),
            truncated: false,
            duration_ms: 240000,
            error: Some("timeout".into()),
        };
        let v: serde_json::Value = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["error"], "timeout");
    }

    #[test]
    fn write_file_request_parses_frozen_names() {
        let json = r#"{"path":"/home/agent/x.txt","contentBase64":"aGk=","mode":420}"#;
        let req: WriteFileRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.path, "/home/agent/x.txt");
        assert_eq!(req.content_base64, "aGk=");
        assert_eq!(req.mode, Some(420));
    }

    #[test]
    fn tree_entry_serializes_type_field() {
        let entry = TreeEntry {
            path: "/home/agent".into(),
            kind: "dir".into(),
            bytes: 0,
        };
        let v: serde_json::Value = serde_json::to_value(&entry).unwrap();
        assert_eq!(v["type"], "dir");
        assert!(v.get("kind").is_none());
    }

    #[test]
    fn screenshot_query_parses_camel_case() {
        let q: ScreenshotQuery = serde_urlencoded::from_str("maxWidth=800").unwrap();
        assert_eq!(q.max_width, Some(800));
    }

    #[test]
    fn healthz_response_shape() {
        let resp = HealthzResponse {
            ok: true,
            containers: 3,
            image: "vibe-sandbox:latest".into(),
        };
        let v: serde_json::Value = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["containers"], 3);
        assert_eq!(v["image"], "vibe-sandbox:latest");
    }

    #[test]
    fn computer_session_request_parses_frozen_field_names() {
        let json = r#"{"viewerId":"user:7","fps":4,"width":720,"quality":55}"#;
        let req: ComputerSessionRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.viewer_id, "user:7");
        assert_eq!(req.fps, Some(4));

        let minimal: ComputerSessionRequest =
            serde_json::from_str(r#"{"viewerId":"user:7"}"#).unwrap();
        assert!(minimal.fps.is_none());
        assert!(minimal.quality.is_none());
    }

    #[test]
    fn computer_frame_response_uses_frozen_names() {
        let resp = ComputerFrameResponse {
            seq: 4,
            image_base64: "aGk=".into(),
            mime: "image/jpeg".into(),
            width: 720,
            height: 405,
            url: "https://a.example/".into(),
            title: "A".into(),
            loading: false,
            control: Control::User,
            captured_at: 1700,
        };
        let v: serde_json::Value = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["imageBase64"], "aGk=");
        assert_eq!(v["capturedAt"], 1700);
        assert_eq!(v["control"], "user");
        assert!(v.get("image_base64").is_none());
    }

    #[test]
    fn computer_state_response_nulls_an_unheld_control() {
        let resp = ComputerStateResponse {
            url: "https://a.example/".into(),
            title: "A".into(),
            loading: true,
            control: Control::Agent,
            holder: None,
            expires_at: None,
            tab_count: 2,
        };
        let v: serde_json::Value = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["control"], "agent");
        assert!(v["holder"].is_null());
        assert!(v["expiresAt"].is_null());
        assert_eq!(v["tabCount"], 2);
    }

    #[test]
    fn computer_input_request_parses_every_frozen_field() {
        let json = r#"{"sessionId":"cs_1","kind":"scroll","x":10.5,"y":20.0,"text":"hi",
            "key":"Enter","deltaY":-120.0,"url":"https://a.example/"}"#;
        let req: ComputerInputRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.session_id, "cs_1");
        assert_eq!(req.kind, "scroll");
        assert_eq!(req.delta_y, Some(-120.0));
        assert_eq!(req.url.as_deref(), Some("https://a.example/"));
    }

    #[test]
    fn computer_control_request_parses_grant() {
        let req: ComputerControlRequest =
            serde_json::from_str(r#"{"action":"grant","sessionId":"cs_1","ttlSeconds":300}"#)
                .unwrap();
        assert_eq!(req.action, "grant");
        assert_eq!(req.ttl_seconds, Some(300));
    }

    #[test]
    fn computer_frame_query_parses_since_and_session() {
        let q: ComputerFrameQuery = serde_urlencoded::from_str("since=7&session=cs_1").unwrap();
        assert_eq!(q.since, Some(7));
        assert_eq!(q.session.as_deref(), Some("cs_1"));

        let bare: ComputerFrameQuery = serde_urlencoded::from_str("").unwrap();
        assert!(bare.since.is_none());
    }

    #[test]
    fn error_response_shape() {
        let resp = ErrorResponse::new("unauthorized");
        let v: serde_json::Value = serde_json::to_value(&resp).unwrap();
        assert_eq!(v["error"], "unauthorized");
    }
}
