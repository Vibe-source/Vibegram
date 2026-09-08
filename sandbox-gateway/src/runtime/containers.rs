use std::collections::HashMap;

use bollard::models::{ContainerInspectResponse, ContainerSummary};
use bollard::query_parameters::{
    CreateContainerOptionsBuilder, InspectContainerOptions, ListContainersOptionsBuilder,
    RemoveContainerOptionsBuilder, StartContainerOptions, StopContainerOptionsBuilder,
};
use bollard::Docker;

use crate::error::{from_docker_error, GatewayError};
use crate::models::{
    CreateSandboxRequest, SandboxActionResponse, SandboxCreatedResponse, SandboxDetailResponse,
    SandboxListResponse,
};
use crate::policy;
use crate::state::{AppState, SandboxEntry};

use super::now_unix;

const LABEL_SANDBOX: &str = "vibe.sandbox";
const LABEL_OWNER_KEY: &str = "vibe.owner_key";
const LABEL_CREATED_AT: &str = "vibe.created_at";

fn label_owner_key(labels: &HashMap<String, String>) -> String {
    labels.get(LABEL_OWNER_KEY).cloned().unwrap_or_default()
}

fn label_created_at(labels: &HashMap<String, String>, fallback: Option<i64>) -> i64 {
    labels
        .get(LABEL_CREATED_AT)
        .and_then(|v| v.parse::<i64>().ok())
        .or(fallback)
        .unwrap_or(0)
}

/// List every container this gateway created.
pub async fn list_labelled(docker: &Docker) -> Result<Vec<ContainerSummary>, GatewayError> {
    let mut filters = HashMap::new();
    filters.insert("label".to_string(), vec![format!("{LABEL_SANDBOX}=1")]);
    let options = ListContainersOptionsBuilder::new()
        .all(true)
        .filters(&filters)
        .build();
    docker
        .list_containers(Some(options))
        .await
        .map_err(from_docker_error)
}

/// Seeds the in-memory map from whatever the daemon already knows about.
pub async fn adopt_on_boot(state: &AppState) -> Result<usize, GatewayError> {
    let containers = list_labelled(&state.docker).await?;
    let mut adopted = 0;
    for c in &containers {
        let Some(name) = c.names.as_ref().and_then(|n| n.first()) else {
            continue;
        };
        let name = name.trim_start_matches('/').to_string();
        let labels = c.labels.clone().unwrap_or_default();
        let created_at = label_created_at(&labels, c.created);
        let entry = SandboxEntry {
            owner_key: label_owner_key(&labels),
            created_at,
            last_used_at: created_at,
            ttl_seconds: None,
        };
        state.upsert(&name, entry);
        adopted += 1;
    }
    Ok(adopted)
}

async fn ensure_volume(docker: &Docker, name: &str) -> Result<(), GatewayError> {
    match docker.inspect_volume(name).await {
        Ok(_) => Ok(()),
        Err(bollard::errors::Error::DockerResponseServerError {
            status_code: 404, ..
        }) => {
            let req = bollard::models::VolumeCreateRequest {
                name: Some(name.to_string()),
                ..Default::default()
            };
            docker
                .create_volume(req)
                .await
                .map(|_| ())
                .map_err(from_docker_error)
        }
        Err(e) => Err(from_docker_error(e)),
    }
}

fn status_of(inspect: &ContainerInspectResponse) -> String {
    inspect
        .state
        .as_ref()
        .and_then(|s| s.status)
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".to_string())
}

async fn start_if_stopped(
    docker: &Docker,
    name: &str,
) -> Result<ContainerInspectResponse, GatewayError> {
    let inspect = docker
        .inspect_container(name, None::<InspectContainerOptions>)
        .await
        .map_err(from_docker_error)?;
    let running = inspect
        .state
        .as_ref()
        .and_then(|s| s.running)
        .unwrap_or(false);
    if !running {
        match docker
            .start_container(name, None::<StartContainerOptions>)
            .await
        {
            Ok(()) => {}
            Err(bollard::errors::Error::DockerResponseServerError {
                status_code: 304, ..
            }) => {}
            Err(e) => return Err(from_docker_error(e)),
        }
        return docker
            .inspect_container(name, None::<InspectContainerOptions>)
            .await
            .map_err(from_docker_error);
    }
    Ok(inspect)
}

/// Creates (or reuses/restarts) the deterministic container for `ownerKey`.
pub async fn ensure_sandbox(
    state: &AppState,
    req: CreateSandboxRequest,
) -> Result<SandboxCreatedResponse, GatewayError> {
    let image = req
        .image
        .clone()
        .unwrap_or_else(|| state.cfg.sandbox_image.clone());
    policy::validate_image(&image, &state.cfg.sandbox_image_allowlist)?;

    let name = policy::container_name(&req.owner_key);
    let already_exists = state.contains(&name)
        || state
            .docker
            .inspect_container(&name, None::<InspectContainerOptions>)
            .await
            .is_ok();

    if already_exists {
        let inspect = start_if_stopped(&state.docker, &name).await?;
        let labels = inspect
            .config
            .as_ref()
            .and_then(|c| c.labels.clone())
            .unwrap_or_default();
        let created_at = state
            .get(&name)
            .map(|e| e.created_at)
            .unwrap_or_else(|| label_created_at(&labels, None));
        if state.contains(&name) {
            state.touch(&name, now_unix());
        } else {
            state.upsert(
                &name,
                SandboxEntry {
                    owner_key: label_owner_key(&labels),
                    created_at,
                    last_used_at: now_unix(),
                    ttl_seconds: req.ttl_seconds,
                },
            );
        }
        return Ok(SandboxCreatedResponse {
            id: name,
            status: status_of(&inspect),
            created_at,
        });
    }

    policy::check_capacity(state.len(), state.cfg.max_containers)?;

    let cpus = req.cpus.unwrap_or(state.cfg.default_cpus);
    let memory_mb = req.memory_mb.unwrap_or(state.cfg.default_memory_mb);
    let pids_limit = req.pids_limit.unwrap_or(state.cfg.pids_limit);
    let volume = policy::volume_name(&req.owner_key, &state.cfg.volume_prefix);
    ensure_volume(&state.docker, &volume).await?;

    let created_at = now_unix();
    let host_config = policy::build_host_config(policy::HostConfigOpts {
        volume_name: &volume,
        memory_mb,
        cpus,
        pids_limit,
        network: req.network,
        sandbox_network: &state.cfg.sandbox_network,
    });
    let env = policy::build_container_env(req.network, state.cfg.sandbox_egress_proxy.as_deref());
    let labels = policy::build_labels(&req.owner_key, created_at);

    let body = bollard::models::ContainerCreateBody {
        image: Some(image),
        user: Some("1000:1000".to_string()),
        working_dir: Some("/home/agent".to_string()),
        env: if env.is_empty() { None } else { Some(env) },
        labels: Some(labels),
        host_config: Some(host_config),
        ..Default::default()
    };
    let options = CreateContainerOptionsBuilder::new().name(&name).build();

    match state.docker.create_container(Some(options), body).await {
        Ok(_) => {}
        Err(bollard::errors::Error::DockerResponseServerError {
            status_code: 409, ..
        }) => {}
        Err(e) => return Err(from_docker_error(e)),
    }

    let inspect = start_if_stopped(&state.docker, &name).await?;
    state.upsert(
        &name,
        SandboxEntry {
            owner_key: req.owner_key,
            created_at,
            last_used_at: created_at,
            ttl_seconds: req.ttl_seconds,
        },
    );

    Ok(SandboxCreatedResponse {
        id: name,
        status: status_of(&inspect),
        created_at,
    })
}

pub async fn get_sandbox(
    state: &AppState,
    id: &str,
) -> Result<SandboxDetailResponse, GatewayError> {
    let inspect = state
        .docker
        .inspect_container(id, None::<InspectContainerOptions>)
        .await
        .map_err(from_docker_error)?;
    let labels = inspect
        .config
        .as_ref()
        .and_then(|c| c.labels.clone())
        .unwrap_or_default();
    let tracked = state.get(id);
    let created_at = tracked
        .as_ref()
        .map(|e| e.created_at)
        .unwrap_or_else(|| label_created_at(&labels, None));
    let last_used_at = tracked
        .as_ref()
        .map(|e| e.last_used_at)
        .unwrap_or(created_at);
    let owner_key = tracked
        .map(|e| e.owner_key)
        .unwrap_or_else(|| label_owner_key(&labels));
    Ok(SandboxDetailResponse {
        id: id.to_string(),
        status: status_of(&inspect),
        owner_key,
        created_at,
        last_used_at,
    })
}

pub async fn list_sandboxes(state: &AppState) -> Result<SandboxListResponse, GatewayError> {
    let containers = list_labelled(&state.docker).await?;
    let mut sandboxes = Vec::with_capacity(containers.len());
    for c in &containers {
        let Some(name) = c.names.as_ref().and_then(|n| n.first()) else {
            continue;
        };
        let name = name.trim_start_matches('/').to_string();
        let labels = c.labels.clone().unwrap_or_default();
        let tracked = state.get(&name);
        let created_at = tracked
            .as_ref()
            .map(|e| e.created_at)
            .unwrap_or_else(|| label_created_at(&labels, c.created));
        let last_used_at = tracked
            .as_ref()
            .map(|e| e.last_used_at)
            .unwrap_or(created_at);
        let owner_key = tracked
            .map(|e| e.owner_key)
            .unwrap_or_else(|| label_owner_key(&labels));
        let status = c
            .state
            .map(|s| s.to_string())
            .unwrap_or_else(|| "unknown".to_string());
        sandboxes.push(SandboxDetailResponse {
            id: name,
            status,
            owner_key,
            created_at,
            last_used_at,
        });
    }
    Ok(SandboxListResponse { sandboxes })
}

pub async fn stop_sandbox(
    state: &AppState,
    id: &str,
) -> Result<SandboxActionResponse, GatewayError> {
    match state
        .docker
        .stop_container(id, Some(StopContainerOptionsBuilder::new().t(10).build()))
        .await
    {
        Ok(()) => {}
        Err(bollard::errors::Error::DockerResponseServerError {
            status_code: 304, ..
        }) => {}
        Err(e) => return Err(from_docker_error(e)),
    }
    let inspect = state
        .docker
        .inspect_container(id, None::<InspectContainerOptions>)
        .await
        .map_err(from_docker_error)?;
    Ok(SandboxActionResponse {
        id: id.to_string(),
        status: status_of(&inspect),
    })
}

/// Removes the container only.
pub async fn delete_sandbox(
    state: &AppState,
    id: &str,
) -> Result<SandboxActionResponse, GatewayError> {
    match state
        .docker
        .stop_container(id, Some(StopContainerOptionsBuilder::new().t(10).build()))
        .await
    {
        Ok(())
        | Err(bollard::errors::Error::DockerResponseServerError {
            status_code: 304, ..
        }) => {}
        Err(e) => return Err(from_docker_error(e)),
    }
    state
        .docker
        .remove_container(
            id,
            Some(
                RemoveContainerOptionsBuilder::new()
                    .force(true)
                    .v(false)
                    .build(),
            ),
        )
        .await
        .map_err(from_docker_error)?;
    state.remove(id);
    Ok(SandboxActionResponse {
        id: id.to_string(),
        status: "removed".to_string(),
    })
}
