use std::sync::Arc;
use std::time::Duration;

use bollard::models::ContainerSummaryStateEnum;
use bollard::query_parameters::StopContainerOptionsBuilder;
use tokio_util::sync::CancellationToken;

use crate::runtime::containers::list_labelled;
use crate::runtime::now_unix;
use crate::state::AppState;

const SWEEP_INTERVAL_SECS: u64 = 60;

pub async fn run(state: Arc<AppState>, shutdown: CancellationToken) {
    let mut interval = tokio::time::interval(Duration::from_secs(SWEEP_INTERVAL_SECS));
    loop {
        tokio::select! {
            _ = shutdown.cancelled() => {
                tracing::info!("reaper: shutting down");
                return;
            }
            _ = interval.tick() => sweep(&state).await,
        }
    }
}

async fn sweep(state: &AppState) {
    state.computer.sweep(&state.cfg, now_unix());

    let containers = match list_labelled(&state.docker).await {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!(error = ?e, "reaper: failed to list containers");
            return;
        }
    };
    let now = now_unix();
    for c in &containers {
        if c.state != Some(ContainerSummaryStateEnum::RUNNING) {
            continue;
        }
        let Some(name) = c.names.as_ref().and_then(|n| n.first()) else {
            continue;
        };
        let name = name.trim_start_matches('/');

        let entry = state.get(name);
        let last_used_at = entry
            .as_ref()
            .map(|e| e.last_used_at)
            .unwrap_or_else(|| c.created.unwrap_or(now));
        let ttl = entry
            .and_then(|e| e.ttl_seconds)
            .unwrap_or(state.cfg.idle_ttl_seconds);
        let idle_secs = now.saturating_sub(last_used_at).max(0) as u64;

        if idle_secs >= ttl {
            tracing::info!(container = name, idle_secs, "reaper: stopping idle sandbox");
            let opts = StopContainerOptionsBuilder::new().t(10).build();
            if let Err(e) = state.docker.stop_container(name, Some(opts)).await {
                tracing::warn!(container = name, error = ?e, "reaper: stop failed");
            }
        }
    }
}
