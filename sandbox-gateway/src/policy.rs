use std::collections::HashMap;

use bollard::models::HostConfig;
use sha2::{Digest, Sha256};

use crate::models::NetworkMode;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum PolicyError {
    #[error("image not allowed: {0}")]
    ImageNotAllowed(String),
    #[error("path must be absolute and under /home/agent or /tmp: {0}")]
    PathNotAllowed(String),
    #[error("file exceeds max size ({0} > {1} bytes)")]
    FileTooLarge(usize, usize),
    #[error("env var not allowed: {0}")]
    EnvKeyNotAllowed(String),
    #[error("sandbox capacity exceeded")]
    CapacityExceeded,
}

fn to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// First 16 hex chars (8 bytes) of sha256(input).
pub fn owner_key_hash(owner_key: &str) -> String {
    let digest = Sha256::digest(owner_key.as_bytes());
    to_hex(&digest)[..16].to_string()
}

pub fn container_name(owner_key: &str) -> String {
    format!("vibe-sb-{}", owner_key_hash(owner_key))
}

pub fn volume_name(owner_key: &str, prefix: &str) -> String {
    format!("{prefix}{}", owner_key_hash(owner_key))
}

pub fn validate_image(image: &str, allowlist: &[String]) -> Result<(), PolicyError> {
    if allowlist.iter().any(|a| a == image) {
        Ok(())
    } else {
        Err(PolicyError::ImageNotAllowed(image.to_string()))
    }
}

/// Requested value clamped to `max`; omitted requests default to `max`.
pub fn clamp_or_max(requested: Option<u64>, max: u64) -> u64 {
    requested.map(|v| v.min(max)).unwrap_or(max)
}

pub fn clamp_or_max_usize(requested: Option<usize>, max: usize) -> usize {
    requested.map(|v| v.min(max)).unwrap_or(max)
}

const ALLOWED_ROOTS: [&str; 2] = ["/home/agent", "/tmp"];

/// Absolute, lexically normalized, and rooted under /home/agent or /tmp.
pub fn validate_file_path(path: &str) -> Result<String, PolicyError> {
    let err = || PolicyError::PathNotAllowed(path.to_string());
    if !path.starts_with('/') || path.contains('\0') {
        return Err(err());
    }
    let mut stack: Vec<&str> = Vec::new();
    for seg in path.split('/') {
        match seg {
            "" | "." => continue,
            ".." => {
                if stack.pop().is_none() {
                    return Err(err());
                }
            }
            s => stack.push(s),
        }
    }
    let normalized = format!("/{}", stack.join("/"));
    let under_root = ALLOWED_ROOTS
        .iter()
        .any(|root| normalized == *root || normalized.starts_with(&format!("{root}/")));
    if under_root {
        Ok(normalized)
    } else {
        Err(err())
    }
}

pub fn validate_file_size(len: usize, max: usize) -> Result<(), PolicyError> {
    if len > max {
        Err(PolicyError::FileTooLarge(len, max))
    } else {
        Ok(())
    }
}

/// Mirrors.
pub fn is_blocked_env_key(key: &str) -> bool {
    let upper = key.to_uppercase();
    matches!(upper.as_str(), "HTTP_PROXY" | "HTTPS_PROXY" | "NO_PROXY")
        || upper.contains("TOKEN")
        || upper.contains("SECRET")
        || upper.contains("KEY")
}

/// The whole exec request is rejected (400) if any env key matches the.
pub fn check_exec_env(env: Option<&HashMap<String, String>>) -> Result<(), PolicyError> {
    if let Some(env) = env {
        for key in env.keys() {
            if is_blocked_env_key(key) {
                return Err(PolicyError::EnvKeyNotAllowed(key.clone()));
            }
        }
    }
    Ok(())
}

pub fn check_capacity(current: usize, max: usize) -> Result<(), PolicyError> {
    if current >= max {
        Err(PolicyError::CapacityExceeded)
    } else {
        Ok(())
    }
}

pub fn memory_bytes(memory_mb: i64) -> i64 {
    memory_mb * 1024 * 1024
}

pub fn nano_cpus(cpus: f64) -> i64 {
    (cpus * 1_000_000_000.0).round() as i64
}

pub struct HostConfigOpts<'a> {
    pub volume_name: &'a str,
    pub memory_mb: i64,
    pub cpus: f64,
    pub pids_limit: i64,
    pub network: NetworkMode,
    pub sandbox_network: &'a str,
}

/// The non-negotiable container hardening policy (spec §3.6):
pub fn build_host_config(opts: HostConfigOpts) -> HostConfig {
    let mut tmpfs = HashMap::new();
    tmpfs.insert("/tmp".to_string(), "size=512m,nosuid,nodev".to_string());

    let network_mode = match opts.network {
        NetworkMode::None => "none".to_string(),
        NetworkMode::Proxy => opts.sandbox_network.to_string(),
    };

    HostConfig {
        cap_drop: Some(vec!["ALL".to_string()]),
        security_opt: Some(vec!["no-new-privileges:true".to_string()]),
        readonly_rootfs: Some(true),
        tmpfs: Some(tmpfs),
        binds: Some(vec![format!("{}:/home/agent", opts.volume_name)]),
        memory: Some(memory_bytes(opts.memory_mb)),
        nano_cpus: Some(nano_cpus(opts.cpus)),
        pids_limit: Some(opts.pids_limit),
        network_mode: Some(network_mode),
        auto_remove: Some(false),
        ..Default::default()
    }
}

/// Proxy env vars set on the container only in `network:"proxy"` mode (spec.
pub fn build_container_env(network: NetworkMode, egress_proxy: Option<&str>) -> Vec<String> {
    match (network, egress_proxy) {
        (NetworkMode::Proxy, Some(proxy)) => vec![
            format!("HTTP_PROXY={proxy}"),
            format!("HTTPS_PROXY={proxy}"),
            format!("http_proxy={proxy}"),
            format!("https_proxy={proxy}"),
            "NO_PROXY=127.0.0.1,localhost".to_string(),
        ],
        _ => Vec::new(),
    }
}

pub fn build_labels(owner_key: &str, created_at: i64) -> HashMap<String, String> {
    let mut labels = HashMap::new();
    labels.insert("vibe.sandbox".to_string(), "1".to_string());
    labels.insert("vibe.owner_key".to_string(), owner_key.to_string());
    labels.insert("vibe.created_at".to_string(), created_at.to_string());
    labels
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn container_and_volume_names_share_the_same_hash_suffix() {
        let owner = "agent:42";
        let cname = container_name(owner);
        let vname = volume_name(owner, "vibe-sandbox-");
        assert!(cname.starts_with("vibe-sb-"));
        assert!(vname.starts_with("vibe-sandbox-"));
        assert_eq!(&cname["vibe-sb-".len()..], &vname["vibe-sandbox-".len()..]);
        assert_eq!(cname["vibe-sb-".len()..].len(), 16);
    }

    #[test]
    fn container_name_is_deterministic() {
        assert_eq!(container_name("agent:1"), container_name("agent:1"));
        assert_ne!(container_name("agent:1"), container_name("agent:2"));
    }

    #[test]
    fn validate_image_accepts_allowlisted() {
        let allow = vec!["vibe-sandbox:latest".to_string()];
        assert!(validate_image("vibe-sandbox:latest", &allow).is_ok());
    }

    #[test]
    fn validate_image_rejects_unlisted() {
        let allow = vec!["vibe-sandbox:latest".to_string()];
        assert_eq!(
            validate_image("evil:latest", &allow),
            Err(PolicyError::ImageNotAllowed("evil:latest".to_string()))
        );
    }

    #[test]
    fn clamp_or_max_defaults_when_omitted() {
        assert_eq!(clamp_or_max(None, 240_000), 240_000);
    }

    #[test]
    fn clamp_or_max_passes_through_when_under_max() {
        assert_eq!(clamp_or_max(Some(1000), 240_000), 1000);
    }

    #[test]
    fn clamp_or_max_clamps_when_over_max() {
        assert_eq!(clamp_or_max(Some(999_999), 240_000), 240_000);
    }

    #[test]
    fn validate_file_path_accepts_home_agent_and_tmp() {
        assert_eq!(
            validate_file_path("/home/agent/x.txt").unwrap(),
            "/home/agent/x.txt"
        );
        assert_eq!(validate_file_path("/tmp/x.txt").unwrap(), "/tmp/x.txt");
        assert_eq!(validate_file_path("/home/agent").unwrap(), "/home/agent");
        assert_eq!(validate_file_path("/tmp").unwrap(), "/tmp");
    }

    #[test]
    fn validate_file_path_rejects_relative() {
        assert!(validate_file_path("home/agent/x.txt").is_err());
    }

    #[test]
    fn validate_file_path_rejects_outside_roots() {
        assert!(validate_file_path("/etc/passwd").is_err());
        assert!(validate_file_path("/root/.ssh/id_rsa").is_err());
    }

    #[test]
    fn validate_file_path_rejects_prefix_collision() {
        assert!(validate_file_path("/home/agentx/x.txt").is_err());
        assert!(validate_file_path("/tmpfoo/x.txt").is_err());
    }

    #[test]
    fn validate_file_path_rejects_traversal_out_of_root() {
        assert!(validate_file_path("/home/agent/../../etc/passwd").is_err());
    }

    #[test]
    fn validate_file_path_normalizes_traversal_within_root() {
        assert_eq!(
            validate_file_path("/home/agent/a/../b.txt").unwrap(),
            "/home/agent/b.txt"
        );
    }

    #[test]
    fn validate_file_size_ok_under_max() {
        assert!(validate_file_size(100, 4_000_000).is_ok());
    }

    #[test]
    fn validate_file_size_rejects_over_max() {
        assert!(validate_file_size(5_000_000, 4_000_000).is_err());
    }

    #[test]
    fn blocked_env_keys_exact_proxy_names() {
        assert!(is_blocked_env_key("HTTP_PROXY"));
        assert!(is_blocked_env_key("HTTPS_PROXY"));
        assert!(is_blocked_env_key("NO_PROXY"));
        assert!(is_blocked_env_key("http_proxy"));
    }

    #[test]
    fn blocked_env_keys_substring_token_secret_key() {
        assert!(is_blocked_env_key("ANTHROPIC_API_KEY"));
        assert!(is_blocked_env_key("SOME_SECRET"));
        assert!(is_blocked_env_key("AUTH_TOKEN"));
        assert!(is_blocked_env_key("my_token_here"));
        assert!(is_blocked_env_key("MONKEY"));
    }

    #[test]
    fn allowed_env_keys_pass() {
        assert!(!is_blocked_env_key("PATH"));
        assert!(!is_blocked_env_key("HOME"));
        assert!(!is_blocked_env_key("LANG"));
    }

    #[test]
    fn check_exec_env_rejects_any_blocked_key() {
        let mut env = HashMap::new();
        env.insert("PATH".to_string(), "/usr/bin".to_string());
        env.insert("API_KEY".to_string(), "shh".to_string());
        assert!(check_exec_env(Some(&env)).is_err());
    }

    #[test]
    fn check_exec_env_accepts_clean_env() {
        let mut env = HashMap::new();
        env.insert("PATH".to_string(), "/usr/bin".to_string());
        assert!(check_exec_env(Some(&env)).is_ok());
    }

    #[test]
    fn check_exec_env_accepts_none() {
        assert!(check_exec_env(None).is_ok());
    }

    #[test]
    fn check_capacity_rejects_at_limit() {
        assert!(check_capacity(32, 32).is_err());
        assert!(check_capacity(33, 32).is_err());
    }

    #[test]
    fn check_capacity_accepts_under_limit() {
        assert!(check_capacity(31, 32).is_ok());
        assert!(check_capacity(0, 32).is_ok());
    }

    #[test]
    fn memory_bytes_converts_mb() {
        assert_eq!(memory_bytes(1024), 1024 * 1024 * 1024);
    }

    #[test]
    fn nano_cpus_converts_fractional_cpus() {
        assert_eq!(nano_cpus(1.0), 1_000_000_000);
        assert_eq!(nano_cpus(0.5), 500_000_000);
    }

    #[test]
    fn host_config_matches_frozen_policy() {
        let hc = build_host_config(HostConfigOpts {
            volume_name: "vibe-sandbox-abc",
            memory_mb: 1024,
            cpus: 1.0,
            pids_limit: 256,
            network: NetworkMode::Proxy,
            sandbox_network: "sandbox-net",
        });
        assert_eq!(hc.cap_drop, Some(vec!["ALL".to_string()]));
        assert_eq!(
            hc.security_opt,
            Some(vec!["no-new-privileges:true".to_string()])
        );
        assert_eq!(hc.readonly_rootfs, Some(true));
        assert_eq!(hc.tmpfs.unwrap().get("/tmp").unwrap(), "size=512m,nosuid,nodev");
        assert_eq!(
            hc.binds,
            Some(vec!["vibe-sandbox-abc:/home/agent".to_string()])
        );
        assert_eq!(hc.memory, Some(1024 * 1024 * 1024));
        assert_eq!(hc.nano_cpus, Some(1_000_000_000));
        assert_eq!(hc.pids_limit, Some(256));
        assert_eq!(hc.network_mode, Some("sandbox-net".to_string()));
        assert_eq!(hc.auto_remove, Some(false));
    }

    #[test]
    fn host_config_network_none_sets_none_mode() {
        let hc = build_host_config(HostConfigOpts {
            volume_name: "v",
            memory_mb: 512,
            cpus: 0.5,
            pids_limit: 64,
            network: NetworkMode::None,
            sandbox_network: "sandbox-net",
        });
        assert_eq!(hc.network_mode, Some("none".to_string()));
    }

    #[test]
    fn container_env_empty_for_network_none() {
        assert!(
            build_container_env(NetworkMode::None, Some("http://egress-proxy:3128")).is_empty()
        );
    }

    #[test]
    fn container_env_sets_all_four_proxy_vars_and_no_proxy() {
        let env = build_container_env(NetworkMode::Proxy, Some("http://egress-proxy:3128"));
        assert!(env.contains(&"HTTP_PROXY=http://egress-proxy:3128".to_string()));
        assert!(env.contains(&"HTTPS_PROXY=http://egress-proxy:3128".to_string()));
        assert!(env.contains(&"http_proxy=http://egress-proxy:3128".to_string()));
        assert!(env.contains(&"https_proxy=http://egress-proxy:3128".to_string()));
        assert!(env.contains(&"NO_PROXY=127.0.0.1,localhost".to_string()));
        assert_eq!(env.len(), 5);
    }

    #[test]
    fn build_labels_has_frozen_keys() {
        let labels = build_labels("agent:1", 1_700_000_000);
        assert_eq!(labels.get("vibe.sandbox").unwrap(), "1");
        assert_eq!(labels.get("vibe.owner_key").unwrap(), "agent:1");
        assert_eq!(labels.get("vibe.created_at").unwrap(), "1700000000");
    }
}
