//! Tests of the feature flag wiring: the region mapping, the item a list or
//! get response carries with inventory.expose_region on and off, the parse
//! of an environment document, and the Flagsmith-backed source with no key,
//! with a local stand-in for Flagsmith, and with nothing listening. None of
//! it needs a database. They are apart
//! from the handler tests because those import actix-web's test module,
//! which shadows the #[test] attribute these use.

use crate::flags::{self, FlagSource};
use crate::InventoryItem;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Stands in for the Flagsmith-backed source: the flags named in it are on,
/// every other one is off.
struct FakeFlags(&'static [&'static str]);

impl FlagSource for FakeFlags {
    fn enabled(&self, name: &str) -> bool {
        self.0.contains(&name)
    }
}

fn item(warehouse: &str, source: &dyn FlagSource) -> InventoryItem {
    InventoryItem::listed(
        "a0000000-0000-0000-0000-000000000002".to_string(),
        "Gadget".to_string(),
        50,
        warehouse.to_string(),
        "2026-09-10 12:00:00".to_string(),
        source,
    )
}

/// What an item serialized to before inventory.expose_region existed. With
/// the flag off the response has to stay exactly this.
const GADGET_WITHOUT_REGION: &str = r#"{"id":"a0000000-0000-0000-0000-000000000002","name":"Gadget","quantity":50,"warehouse":"west","created_at":"2026-09-10 12:00:00"}"#;

#[test]
fn warehouses_map_to_regions() {
    assert_eq!(flags::region_for("east"), Some("us-east"));
    assert_eq!(flags::region_for("west"), Some("eu-west"));
    assert_eq!(flags::region_for("north"), None);
    assert_eq!(flags::region_for(""), None);
}

#[test]
fn with_the_flag_off_an_item_is_unchanged() {
    for source in [
        &flags::Off as &dyn FlagSource,
        &FakeFlags(&["orders.forward_region"]),
    ] {
        let json = serde_json::to_string(&item("west", source)).unwrap();
        assert_eq!(json, GADGET_WITHOUT_REGION);
    }
}

#[test]
fn with_the_flag_on_an_item_carries_its_region() {
    let on = FakeFlags(&[flags::EXPOSE_REGION]);

    let west = serde_json::to_value(item("west", &on)).unwrap();
    assert_eq!(west["region"], "eu-west");
    let east = serde_json::to_value(item("east", &on)).unwrap();
    assert_eq!(east["region"], "us-east");

    // A warehouse with no region gets no field, not a null.
    let json = serde_json::to_string(&item("north", &on)).unwrap();
    assert!(!json.contains("region"), "{}", json);
}

/// No key and a client-side key both read every flag as off, without a
/// request: Flagsmith serves the environment document only to a server-side
/// key.
#[test]
fn without_a_server_side_key_every_flag_is_off() {
    for key in ["", "B62qaMZNwfiqT76p38ggrQ"] {
        let source = flags::new(key.to_string(), String::new());
        assert!(!source.enabled(flags::EXPOSE_REGION), "key {:?}", key);
        let json = serde_json::to_string(&item("west", source.as_ref())).unwrap();
        assert_eq!(json, GADGET_WITHOUT_REGION);
    }
}

/// A minimal environment document, in the shape Flagsmith serves at
/// /api/v1/environment-document/ to a server-side key.
const ENVIRONMENT_DOCUMENT: &str = r#"{
  "api_key": "client-key",
  "name": "production",
  "project": {
    "name": "example-stack",
    "organisation": {"id": 1, "name": "example-stack", "feature_analytics": false, "stop_serving_flags": false, "persist_trait_data": true},
    "segments": [],
    "id": 1,
    "hide_disabled_flags": false
  },
  "segment_overrides": [],
  "id": 1,
  "feature_states": [
    {"id": 1, "feature": {"id": 1, "name": "inventory.expose_region", "type": "STANDARD"}, "enabled": true, "feature_state_value": null, "multivariate_feature_state_values": [], "featurestate_uuid": "40eb539d-3713-4720-bbd4-829dbef10d51"},
    {"id": 2, "feature": {"id": 2, "name": "orders.forward_region", "type": "STANDARD"}, "enabled": false, "feature_state_value": null, "multivariate_feature_state_values": [], "featurestate_uuid": "40eb539d-3713-4720-bbd4-829dbef10d52"}
  ],
  "updated_at": "2026-09-10 12:00:00.000000",
  "identity_overrides": []
}"#;

#[test]
fn a_document_parses_to_the_state_of_each_flag() {
    let flags = flags::parse_document(ENVIRONMENT_DOCUMENT).unwrap();
    assert_eq!(flags.get("inventory.expose_region"), Some(&true));
    assert_eq!(flags.get("orders.forward_region"), Some(&false));
    assert_eq!(flags.get("pricing.regional_currency"), None);
}

/// A document that is not an environment is an error, never a panic, so the
/// poller keeps the last flags.
#[test]
fn a_malformed_document_is_an_error() {
    assert!(flags::parse_document(r#"{"not": "an environment"}"#).is_err());
    assert!(flags::parse_document("").is_err());
}

/// Serves the environment document to every request on a local port, and
/// records the request lines and headers it saw.
fn serve_environment_document() -> (String, Arc<std::sync::Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/api/v1", listener.local_addr().unwrap());
    let seen = Arc::new(std::sync::Mutex::new(Vec::new()));
    let log = Arc::clone(&seen);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buf = [0u8; 8192];
            let n = stream.read(&mut buf).unwrap_or(0);
            log.lock()
                .unwrap()
                .push(String::from_utf8_lossy(&buf[..n]).to_string());
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                ENVIRONMENT_DOCUMENT.len(),
                ENVIRONMENT_DOCUMENT
            );
            let _ = stream.write_all(response.as_bytes());
        }
    });
    (url, seen)
}

#[test]
fn reads_flags_from_the_environment_document() {
    let (url, seen) = serve_environment_document();
    // No trailing slash: new adds the one the SDK needs.
    let source = flags::new("ser.test-key".to_string(), url);

    let deadline = Instant::now() + Duration::from_secs(10);
    while !source.enabled(flags::EXPOSE_REGION) {
        assert!(
            Instant::now() < deadline,
            "inventory.expose_region never read as on"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(!source.enabled("orders.forward_region"));
    assert!(!source.enabled("pricing.regional_currency"));

    let requests = seen.lock().unwrap();
    let first = requests.first().expect("no request reached the server");
    assert!(
        first.starts_with("GET /api/v1/environment-document/ "),
        "{}",
        first
    );
    assert!(
        first
            .to_ascii_lowercase()
            .contains("x-environment-key: ser.test-key"),
        "{}",
        first
    );
}

/// Flagsmith unreachable at startup is every flag off, not a panic.
#[test]
fn with_flagsmith_unreachable_every_flag_is_off() {
    let url = {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        format!("http://{}/api/v1/", listener.local_addr().unwrap())
    };
    let source = flags::new("ser.test-key".to_string(), url);
    for _ in 0..10 {
        assert!(!source.enabled(flags::EXPOSE_REGION));
        std::thread::sleep(Duration::from_millis(50));
    }
}
