//! Live-daemon smoke test.

use bollard::Docker;

#[tokio::test]
async fn ping_the_configured_socket() {
    if std::env::var("SANDBOX_LIVE_TEST").ok().as_deref() != Some("1") {
        eprintln!(
            "skipping live_socket::ping_the_configured_socket (set SANDBOX_LIVE_TEST=1 to run)"
        );
        return;
    }
    let socket = std::env::var("CONTAINER_SOCKET")
        .unwrap_or_else(|_| "unix:///run/podman/podman.sock".to_string());
    let docker = Docker::connect_with_host(&socket).expect("connect to CONTAINER_SOCKET");
    docker.ping().await.expect("ping the container socket");
}
