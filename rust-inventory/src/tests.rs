//! Handler tests that need no database. The state holds no client, so every
//! path asserted here is one that answers before a query: authentication,
//! request validation, and the liveness endpoint. Anything that reaches the
//! database answers 503 and is covered by the smoke test against the cluster.

use crate::{routes, AppState};
use actix_web::{http::StatusCode, test, web, App};
use std::sync::Arc;
use tokio::sync::Mutex;

const TOKEN: &str = "test-token";

fn state() -> Arc<AppState> {
    Arc::new(AppState {
        db: Mutex::new(None),
        db_url: String::new(),
        api_token: TOKEN.to_string(),
    })
}

macro_rules! test_app {
    () => {
        test::init_service(
            App::new()
                .app_data(web::Data::new(state()))
                .configure(routes),
        )
        .await
    };
}

#[actix_web::test]
async fn health_answers_without_a_token() {
    let app = test_app!();
    let req = test::TestRequest::get().uri("/healthz").to_request();
    let resp = test::call_service(&app, req).await;

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value = test::read_body_json(resp).await;
    assert_eq!(body["status"], "ok");
}

#[actix_web::test]
async fn the_api_rejects_a_missing_or_wrong_token() {
    let app = test_app!();

    for (method, uri) in [
        ("GET", "/api/v1/inventory"),
        ("POST", "/api/v1/inventory"),
        (
            "GET",
            "/api/v1/inventory/a0000000-0000-0000-0000-000000000001",
        ),
        (
            "DELETE",
            "/api/v1/inventory/a0000000-0000-0000-0000-000000000001",
        ),
    ] {
        // No header at all, a wrong token, and the right token without the
        // Bearer scheme, which is not a match either.
        for header in [None, Some("Bearer wrong-token"), Some(TOKEN)] {
            let mut req = match method {
                "GET" => test::TestRequest::get(),
                "POST" => test::TestRequest::post(),
                _ => test::TestRequest::delete(),
            }
            .uri(uri);
            if let Some(value) = header {
                req = req.insert_header(("Authorization", value));
            }
            // A POST needs a body the extractor accepts, or it fails before
            // the token is looked at.
            if method == "POST" {
                req = req.set_json(serde_json::json!({
                    "name": "Widget", "quantity": 1, "warehouse": "east"
                }));
            }
            let resp = test::call_service(&app, req.to_request()).await;
            assert_eq!(
                resp.status(),
                StatusCode::UNAUTHORIZED,
                "{} {} with {:?} was not rejected",
                method,
                uri,
                header
            );
            let body: serde_json::Value = test::read_body_json(resp).await;
            assert_eq!(body, serde_json::json!({"error": "unauthorized"}));
        }
    }
}

#[actix_web::test]
async fn create_rejects_an_empty_name() {
    let app = test_app!();
    let req = test::TestRequest::post()
        .uri("/api/v1/inventory")
        .insert_header(("Authorization", format!("Bearer {}", TOKEN)))
        .set_json(serde_json::json!({"name": "", "quantity": 1, "warehouse": "east"}))
        .to_request();
    let resp = test::call_service(&app, req).await;

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body: serde_json::Value = test::read_body_json(resp).await;
    assert_eq!(body["error"], "name is required");
}

/// The service rejects a negative quantity before it reaches the database. The
/// column's own CHECK constraint is a second guard, and only the smoke test
/// against a live PostgreSQL exercises that one.
#[actix_web::test]
async fn create_rejects_a_negative_quantity() {
    let app = test_app!();
    let req = test::TestRequest::post()
        .uri("/api/v1/inventory")
        .insert_header(("Authorization", format!("Bearer {}", TOKEN)))
        .set_json(serde_json::json!({"name": "Widget", "quantity": -1, "warehouse": "east"}))
        .to_request();
    let resp = test::call_service(&app, req).await;

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body: serde_json::Value = test::read_body_json(resp).await;
    assert_eq!(body["error"], "quantity must be non-negative");
}

#[actix_web::test]
async fn an_identifier_that_is_not_a_uuid_is_rejected() {
    let app = test_app!();

    for method in ["GET", "DELETE"] {
        let req = match method {
            "GET" => test::TestRequest::get(),
            _ => test::TestRequest::delete(),
        }
        .uri("/api/v1/inventory/not-a-uuid")
        .insert_header(("Authorization", format!("Bearer {}", TOKEN)))
        .to_request();
        let resp = test::call_service(&app, req).await;

        assert_eq!(resp.status(), StatusCode::BAD_REQUEST, "{}", method);
        let body: serde_json::Value = test::read_body_json(resp).await;
        assert_eq!(body["error"], "invalid id");
    }
}

/// A valid request with no client answers 503 and never panics, which is what
/// keeps the rest of these tests honest: they pass on the handler's own logic,
/// not because a query silently succeeded.
#[actix_web::test]
async fn a_valid_request_without_a_client_is_unavailable() {
    let app = test_app!();
    let req = test::TestRequest::get()
        .uri("/api/v1/inventory")
        .insert_header(("Authorization", format!("Bearer {}", TOKEN)))
        .to_request();
    let resp = test::call_service(&app, req).await;

    assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body: serde_json::Value = test::read_body_json(resp).await;
    assert_eq!(body, serde_json::json!({"error": "database not connected"}));
}
