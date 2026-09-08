use axum::http::StatusCode;
use axum::response::{IntoResponse, Json, Response};

use crate::models::ErrorResponse;
use crate::policy::PolicyError;

#[derive(Debug, thiserror::Error)]
pub enum GatewayError {
    #[error("unauthorized")]
    Unauthorized,
    #[error("{0}")]
    BadRequest(String),
    #[error("not_found")]
    NotFound,
    #[error("{0}")]
    Conflict(String),
    #[error("{0}")]
    TooManyRequests(String),
    #[error("{0}")]
    PayloadTooLarge(String),
    #[error("{0}")]
    Internal(#[from] anyhow::Error),
}

impl GatewayError {
    fn status_and_code(&self) -> (StatusCode, String) {
        match self {
            GatewayError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized".to_string()),
            GatewayError::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg.clone()),
            GatewayError::NotFound => (StatusCode::NOT_FOUND, "not_found".to_string()),
            GatewayError::Conflict(msg) => (StatusCode::CONFLICT, msg.clone()),
            GatewayError::TooManyRequests(msg) => (StatusCode::TOO_MANY_REQUESTS, msg.clone()),
            GatewayError::PayloadTooLarge(msg) => (StatusCode::PAYLOAD_TOO_LARGE, msg.clone()),
            GatewayError::Internal(err) => {
                tracing::error!(error = %err, "internal error");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "internal_error".to_string(),
                )
            }
        }
    }
}

impl IntoResponse for GatewayError {
    fn into_response(self) -> Response {
        let (status, code) = self.status_and_code();
        (status, Json(ErrorResponse::new(code))).into_response()
    }
}

impl From<PolicyError> for GatewayError {
    fn from(err: PolicyError) -> Self {
        match err {
            PolicyError::CapacityExceeded => GatewayError::Conflict(err.to_string()),
            other => GatewayError::BadRequest(other.to_string()),
        }
    }
}

/// Maps a bollard Docker-API error onto the gateway's error surface by HTTP.
pub fn from_docker_error(err: bollard::errors::Error) -> GatewayError {
    if let bollard::errors::Error::DockerResponseServerError {
        status_code,
        message,
    } = &err
    {
        return match *status_code {
            404 => GatewayError::NotFound,
            409 => GatewayError::Conflict(message.clone()),
            400 => GatewayError::BadRequest(message.clone()),
            _ => GatewayError::Internal(anyhow::anyhow!(err.to_string())),
        };
    }
    GatewayError::Internal(anyhow::anyhow!(err.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::to_bytes;

    #[tokio::test]
    async fn unauthorized_maps_to_401_with_error_body() {
        let resp = GatewayError::Unauthorized.into_response();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
        let body = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(v["error"], "unauthorized");
    }

    #[test]
    fn docker_404_maps_to_not_found() {
        let err = bollard::errors::Error::DockerResponseServerError {
            status_code: 404,
            message: "no such container".into(),
        };
        assert!(matches!(from_docker_error(err), GatewayError::NotFound));
    }

    #[test]
    fn docker_409_maps_to_conflict() {
        let err = bollard::errors::Error::DockerResponseServerError {
            status_code: 409,
            message: "name in use".into(),
        };
        assert!(matches!(from_docker_error(err), GatewayError::Conflict(_)));
    }

    #[test]
    fn docker_500_maps_to_internal() {
        let err = bollard::errors::Error::DockerResponseServerError {
            status_code: 500,
            message: "daemon error".into(),
        };
        assert!(matches!(from_docker_error(err), GatewayError::Internal(_)));
    }

    #[test]
    fn policy_capacity_error_maps_to_conflict() {
        let err: GatewayError = PolicyError::CapacityExceeded.into();
        assert!(matches!(err, GatewayError::Conflict(_)));
    }

    #[test]
    fn policy_validation_errors_map_to_bad_request() {
        let err: GatewayError = PolicyError::ImageNotAllowed("x".to_string()).into();
        assert!(matches!(err, GatewayError::BadRequest(_)));
    }
}
