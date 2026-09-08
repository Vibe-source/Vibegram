mod auth;
mod config;
mod error;
mod models;
mod policy;
mod reaper;
mod routes;
mod runtime;
mod state;

use std::sync::Arc;

use bollard::Docker;
use tokio_util::sync::CancellationToken;

use config::Config;
use state::AppState;

#[tokio::main]
async fn main() {
    let cfg = match Config::from_env() {
        Ok(cfg) => cfg,
        Err(e) => {
            eprintln!("sandbox-gateway: config error: {e}");
            std::process::exit(1);
        }
    };

    init_tracing(&cfg.log_format);

    let docker = match Docker::connect_with_host(&cfg.container_socket) {
        Ok(docker) => docker,
        Err(e) => {
            tracing::error!(error = %e, socket = %cfg.container_socket, "failed to connect to container socket");
            std::process::exit(1);
        }
    };

    let port = cfg.port;
    let image = cfg.sandbox_image.clone();
    let state = Arc::new(AppState::new(cfg, docker));

    match runtime::containers::adopt_on_boot(&state).await {
        Ok(n) => tracing::info!(adopted = n, "adopted existing sandboxes on boot"),
        Err(e) => tracing::warn!(error = ?e, "boot-time adoption failed (continuing)"),
    }

    let shutdown = CancellationToken::new();
    let reaper_handle = tokio::spawn(reaper::run(state.clone(), shutdown.clone()));

    let app = routes::build(state);
    let addr = format!("0.0.0.0:{port}");
    let listener = match tokio::net::TcpListener::bind(&addr).await {
        Ok(listener) => listener,
        Err(e) => {
            tracing::error!(error = %e, addr, "failed to bind");
            std::process::exit(1);
        }
    };

    tracing::info!(addr, image, "sandbox-gateway listening");
    let serve =
        axum::serve(listener, app).with_graceful_shutdown(shutdown_signal(shutdown.clone()));
    if let Err(e) = serve.await {
        tracing::error!(error = %e, "server error");
    }

    shutdown.cancel();
    let _ = reaper_handle.await;
}

async fn shutdown_signal(token: CancellationToken) {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to install ctrl_c handler")
    };
    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to install SIGTERM handler")
            .recv()
            .await;
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {}
        _ = terminate => {}
    }
    token.cancel();
}

fn init_tracing(log_format: &str) {
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;
    use tracing_subscriber::EnvFilter;

    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    if log_format == "json" {
        tracing_subscriber::registry()
            .with(filter)
            .with(tracing_subscriber::fmt::layer().json())
            .init();
    } else {
        tracing_subscriber::registry()
            .with(filter)
            .with(tracing_subscriber::fmt::layer())
            .init();
    }
}
