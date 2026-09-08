use std::io::{Cursor, Read};

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use bollard::query_parameters::{
    DownloadFromContainerOptionsBuilder, UploadToContainerOptionsBuilder,
};
use bollard::Docker;
use futures_util::StreamExt;

use crate::error::{from_docker_error, GatewayError};
use crate::models::{
    ReadFileResponse, TreeEntry, TreeResponse, WriteFileRequest, WriteFileResponse,
};
use crate::policy;
use crate::state::AppState;

use super::now_unix;

const ROOTS: [&str; 2] = ["/home/agent", "/tmp"];

/// Splits a validated path into (mount root.
fn split_root_and_relative(path: &str) -> Result<(&'static str, String), GatewayError> {
    for root in ROOTS {
        if let Some(rel) = path.strip_prefix(&format!("{root}/")) {
            return Ok((root, rel.to_string()));
        }
    }
    Err(GatewayError::BadRequest(
        "path must not be a bare root directory".to_string(),
    ))
}

fn parent_dir(path: &str) -> String {
    match path.rfind('/') {
        Some(0) => "/".to_string(),
        Some(idx) => path[..idx].to_string(),
        None => "/".to_string(),
    }
}

const MAX_TAR_BYTES: usize = 64 * 1024 * 1024;

async fn collect_capped<S, B>(mut stream: S, max_bytes: usize) -> Result<Vec<u8>, GatewayError>
where
    S: futures_util::Stream<Item = Result<B, GatewayError>> + Unpin,
    B: AsRef<[u8]>,
{
    let mut buf = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        let new_len = buf.len().checked_add(chunk.as_ref().len()).ok_or_else(|| {
            GatewayError::PayloadTooLarge(format!("container archive exceeds {max_bytes} bytes"))
        })?;
        if new_len > max_bytes {
            return Err(GatewayError::PayloadTooLarge(format!(
                "container archive exceeds {max_bytes} bytes"
            )));
        }
        buf.extend_from_slice(chunk.as_ref());
    }
    Ok(buf)
}

async fn download_tar(
    docker: &Docker,
    container_id: &str,
    path: &str,
) -> Result<Vec<u8>, GatewayError> {
    let options = DownloadFromContainerOptionsBuilder::new()
        .path(path)
        .build();
    let stream = docker
        .download_from_container(container_id, Some(options))
        .map(|chunk| chunk.map_err(from_docker_error));
    collect_capped(stream, MAX_TAR_BYTES).await
}

pub async fn write_file(
    state: &AppState,
    container_id: &str,
    req: WriteFileRequest,
) -> Result<WriteFileResponse, GatewayError> {
    let path = policy::validate_file_path(&req.path)?;
    let data = BASE64
        .decode(&req.content_base64)
        .map_err(|e| GatewayError::BadRequest(format!("invalid base64: {e}")))?;
    policy::validate_file_size(data.len(), state.cfg.max_file_bytes)?;
    let (root, rel) = split_root_and_relative(&path)?;

    let mut header = tar::Header::new_gnu();
    header.set_size(data.len() as u64);
    header.set_mode(req.mode.unwrap_or(0o644));
    header.set_uid(1000);
    header.set_gid(1000);
    header.set_mtime(now_unix().max(0) as u64);

    let mut builder = tar::Builder::new(Vec::new());
    builder
        .append_data(&mut header, rel, data.as_slice())
        .map_err(|e| GatewayError::Internal(anyhow::anyhow!(e)))?;
    let tar_bytes = builder
        .into_inner()
        .map_err(|e| GatewayError::Internal(anyhow::anyhow!(e)))?;

    let options = UploadToContainerOptionsBuilder::new().path(root).build();
    state
        .docker
        .upload_to_container(
            container_id,
            Some(options),
            bollard::body_full(tar_bytes.into()),
        )
        .await
        .map_err(from_docker_error)?;

    state.touch(container_id, now_unix());
    Ok(WriteFileResponse {
        path,
        bytes: data.len() as u64,
    })
}

pub async fn read_file(
    state: &AppState,
    container_id: &str,
    path: &str,
) -> Result<ReadFileResponse, GatewayError> {
    let path = policy::validate_file_path(path)?;
    let tar_bytes = download_tar(&state.docker, container_id, &path).await?;
    let mut archive = tar::Archive::new(Cursor::new(tar_bytes));
    let entries = archive
        .entries()
        .map_err(|e| GatewayError::Internal(anyhow::anyhow!(e)))?;
    for entry in entries {
        let mut entry = entry.map_err(|e| GatewayError::Internal(anyhow::anyhow!(e)))?;
        if !entry.header().entry_type().is_file() {
            continue;
        }
        let size = entry.header().size().unwrap_or(0) as usize;
        policy::validate_file_size(size, state.cfg.max_file_bytes)?;
        let mut buf = Vec::with_capacity(size);
        entry
            .read_to_end(&mut buf)
            .map_err(|e| GatewayError::Internal(anyhow::anyhow!(e)))?;
        state.touch(container_id, now_unix());
        return Ok(ReadFileResponse {
            path,
            content_base64: BASE64.encode(&buf),
            bytes: buf.len() as u64,
        });
    }
    Err(GatewayError::NotFound)
}

pub async fn tree(
    state: &AppState,
    container_id: &str,
    path: Option<String>,
    depth: Option<u32>,
) -> Result<TreeResponse, GatewayError> {
    let root = policy::validate_file_path(&path.unwrap_or_else(|| "/home/agent".to_string()))?;
    let depth = depth.unwrap_or(3).min(8);

    let tar_bytes = download_tar(&state.docker, container_id, &root).await?;
    let mut archive = tar::Archive::new(Cursor::new(tar_bytes));
    let parent = parent_dir(&root);
    let entries_iter = archive
        .entries()
        .map_err(|e| GatewayError::Internal(anyhow::anyhow!(e)))?;

    let mut entries = Vec::new();
    for entry in entries_iter {
        let entry = entry.map_err(|e| GatewayError::Internal(anyhow::anyhow!(e)))?;
        let entry_name = entry
            .path()
            .map_err(|e| GatewayError::Internal(anyhow::anyhow!(e)))?
            .to_string_lossy()
            .to_string();
        let entry_name = entry_name.trim_end_matches('/');
        let entry_depth = entry_name.matches('/').count() as u32;
        if entry_depth > depth {
            continue;
        }
        let full_path = if parent == "/" {
            format!("/{entry_name}")
        } else {
            format!("{parent}/{entry_name}")
        };
        let kind = if entry.header().entry_type().is_dir() {
            "dir"
        } else {
            "file"
        };
        entries.push(TreeEntry {
            path: full_path,
            kind: kind.to_string(),
            bytes: entry.header().size().unwrap_or(0),
        });
    }
    state.touch(container_id, now_unix());
    Ok(TreeResponse { entries })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_root_and_relative_home_agent() {
        let (root, rel) = split_root_and_relative("/home/agent/foo/bar.txt").unwrap();
        assert_eq!(root, "/home/agent");
        assert_eq!(rel, "foo/bar.txt");
    }

    #[test]
    fn split_root_and_relative_tmp() {
        let (root, rel) = split_root_and_relative("/tmp/x.txt").unwrap();
        assert_eq!(root, "/tmp");
        assert_eq!(rel, "x.txt");
    }

    #[test]
    fn split_root_and_relative_rejects_bare_root() {
        assert!(split_root_and_relative("/home/agent").is_err());
        assert!(split_root_and_relative("/tmp").is_err());
    }

    #[test]
    fn parent_dir_of_nested_path() {
        assert_eq!(parent_dir("/home/agent/foo"), "/home/agent");
    }

    #[test]
    fn parent_dir_of_top_level_root() {
        assert_eq!(parent_dir("/tmp"), "/");
    }

    #[tokio::test]
    async fn collect_capped_accepts_small_stream() {
        let stream = futures_util::stream::iter(vec![
            Ok::<_, GatewayError>(vec![1_u8, 2]),
            Ok(vec![3_u8]),
        ]);
        assert_eq!(collect_capped(stream, 3).await.unwrap(), vec![1, 2, 3]);
    }

    #[tokio::test]
    async fn collect_capped_rejects_stream_over_limit() {
        let stream = futures_util::stream::iter(vec![
            Ok::<_, GatewayError>(vec![1_u8, 2]),
            Ok(vec![3_u8, 4]),
        ]);
        assert!(matches!(
            collect_capped(stream, 3).await,
            Err(GatewayError::PayloadTooLarge(_))
        ));
    }
}
