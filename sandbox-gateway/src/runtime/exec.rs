use std::time::{Duration, Instant};

use bollard::container::LogOutput;
use bollard::exec::{CreateExecOptions, StartExecOptions, StartExecResults};
use bollard::Docker;
use futures_util::StreamExt;

use crate::error::{from_docker_error, GatewayError};
use crate::models::{ExecRequest, ExecResponse};
use crate::policy;
use crate::state::AppState;

fn append_capped(buf: &mut Vec<u8>, chunk: &[u8], max: usize, truncated: &mut bool) {
    if buf.len() >= max {
        *truncated = true;
        return;
    }
    let remaining = max - buf.len();
    if chunk.len() > remaining {
        buf.extend_from_slice(&chunk[..remaining]);
        *truncated = true;
    } else {
        buf.extend_from_slice(chunk);
    }
}

/// Retries briefly:
async fn wait_exit_code(docker: &Docker, exec_id: &str) -> i32 {
    for _ in 0..5 {
        if let Ok(info) = docker.inspect_exec(exec_id).await {
            if let Some(code) = info.exit_code {
                return code as i32;
            }
            if info.running == Some(false) {
                return 0;
            }
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    0
}

/// Best-effort:
async fn kill_exec_tree(docker: &Docker, container_id: &str, exec_id: &str) {
    let pid = docker
        .inspect_exec(exec_id)
        .await
        .ok()
        .and_then(|info| info.pid);
    let Some(pid) = pid else { return };
    let kill_cmd = vec![
        "sh".to_string(),
        "-c".to_string(),
        format!("kill -9 -- -{pid} {pid} 2>/dev/null || true"),
    ];
    let create = docker
        .create_exec(
            container_id,
            CreateExecOptions {
                cmd: Some(kill_cmd),
                ..Default::default()
            },
        )
        .await;
    match create {
        Ok(created) => {
            let opts = StartExecOptions {
                detach: true,
                ..Default::default()
            };
            if let Err(e) = docker.start_exec(&created.id, Some(opts)).await {
                tracing::warn!(error = %e, "failed to run timeout-kill exec");
            }
        }
        Err(e) => tracing::warn!(error = %e, "failed to create timeout-kill exec"),
    }
}

pub async fn exec(
    state: &AppState,
    container_id: &str,
    req: ExecRequest,
) -> Result<ExecResponse, GatewayError> {
    if req.cmd.is_empty() {
        return Err(GatewayError::BadRequest(
            "cmd must not be empty".to_string(),
        ));
    }
    policy::check_exec_env(req.env.as_ref())?;

    let timeout_ms = policy::clamp_or_max(req.timeout_ms, state.cfg.exec_max_timeout_ms);
    let max_output = policy::clamp_or_max_usize(req.max_output_bytes, state.cfg.max_output_bytes);
    let env: Option<Vec<String>> = req
        .env
        .map(|m| m.into_iter().map(|(k, v)| format!("{k}={v}")).collect());

    let create = state
        .docker
        .create_exec(
            container_id,
            CreateExecOptions {
                cmd: Some(req.cmd),
                attach_stdout: Some(true),
                attach_stderr: Some(true),
                env,
                working_dir: req.cwd,
                ..Default::default()
            },
        )
        .await
        .map_err(from_docker_error)?;

    let start = Instant::now();
    let started = state
        .docker
        .start_exec(&create.id, None::<StartExecOptions>)
        .await
        .map_err(from_docker_error)?;
    let StartExecResults::Attached { mut output, .. } = started else {
        return Err(GatewayError::Internal(anyhow::anyhow!(
            "exec started detached unexpectedly"
        )));
    };

    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let mut truncated = false;

    let drain = async {
        while let Some(chunk) = output.next().await {
            match chunk {
                Ok(LogOutput::StdOut { message }) => {
                    append_capped(&mut stdout, &message, max_output, &mut truncated)
                }
                Ok(LogOutput::StdErr { message }) => {
                    append_capped(&mut stderr, &message, max_output, &mut truncated)
                }
                Ok(_) => {}
                Err(e) => return Err(from_docker_error(e)),
            }
        }
        Ok::<(), GatewayError>(())
    };

    match tokio::time::timeout(Duration::from_millis(timeout_ms), drain).await {
        Ok(Ok(())) => {
            let exit_code = wait_exit_code(&state.docker, &create.id).await;
            Ok(ExecResponse {
                exit_code,
                stdout: String::from_utf8_lossy(&stdout).to_string(),
                stderr: String::from_utf8_lossy(&stderr).to_string(),
                truncated,
                duration_ms: start.elapsed().as_millis() as u64,
                error: None,
            })
        }
        Ok(Err(e)) => Err(e),
        Err(_) => {
            kill_exec_tree(&state.docker, container_id, &create.id).await;
            Ok(ExecResponse {
                exit_code: 124,
                stdout: String::from_utf8_lossy(&stdout).to_string(),
                stderr: String::from_utf8_lossy(&stderr).to_string(),
                truncated: false,
                duration_ms: start.elapsed().as_millis() as u64,
                error: Some("timeout".to_string()),
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn append_capped_writes_under_limit() {
        let mut buf = Vec::new();
        let mut truncated = false;
        append_capped(&mut buf, b"hello", 100, &mut truncated);
        assert_eq!(buf, b"hello");
        assert!(!truncated);
    }

    #[test]
    fn append_capped_truncates_at_limit() {
        let mut buf = Vec::new();
        let mut truncated = false;
        append_capped(&mut buf, b"hello world", 5, &mut truncated);
        assert_eq!(buf, b"hello");
        assert!(truncated);
    }

    #[test]
    fn append_capped_noop_once_full() {
        let mut buf = b"abcde".to_vec();
        let mut truncated = false;
        append_capped(&mut buf, b"more", 5, &mut truncated);
        assert_eq!(buf, b"abcde");
        assert!(truncated);
    }

    #[test]
    fn append_capped_across_multiple_chunks() {
        let mut buf = Vec::new();
        let mut truncated = false;
        append_capped(&mut buf, b"ab", 5, &mut truncated);
        append_capped(&mut buf, b"cd", 5, &mut truncated);
        assert!(!truncated);
        append_capped(&mut buf, b"efgh", 5, &mut truncated);
        assert_eq!(buf, b"abcde");
        assert!(truncated);
    }
}
