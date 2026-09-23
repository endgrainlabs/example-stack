//! Feature flags from Flagsmith. Every ten seconds a thread fetches the
//! environment document Flagsmith serves to a server-side key and copies the
//! on/off state of each flag into a snapshot the request handlers read, so a
//! request never waits on Flagsmith. A service with no key, or one that has
//! never reached Flagsmith, reads every flag as off, which is how it behaves
//! without Flagsmith at all; once a fetch has succeeded, the last flags are
//! kept while Flagsmith is unreachable.
//!
//! This is a client for one endpoint rather than the `flagsmith` crate. At
//! 3.1.1 the crate holds its lock across the refresh request and panics on a
//! document it cannot parse, and its TLS stack needs a C toolchain in the
//! image build. Segments, identities, and multivariate values are not
//! evaluated: the stack's flags are booleans at the environment level.

use serde::Deserialize;
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::thread;
use std::time::Duration;

/// Adds a region to each item in the list and get responses.
pub const EXPOSE_REGION: &str = "inventory.expose_region";

/// The in-cluster Flagsmith API.
pub const DEFAULT_API_URL: &str = "http://flagsmith.flagsmith.svc.cluster.local:8000/api/v1/";

/// How often the environment document is fetched again.
const REFRESH_INTERVAL: Duration = Duration::from_secs(10);

/// How long one fetch may take, shorter than the interval so a slow
/// Flagsmith cannot pile requests up.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

/// Answers whether a feature flag is on. The snapshot and the tests' fakes
/// both implement it.
pub trait FlagSource: Send + Sync {
    fn enabled(&self, name: &str) -> bool;
}

/// The source for a service with no key: every flag is off.
pub struct Off;

impl FlagSource for Off {
    fn enabled(&self, _name: &str) -> bool {
        false
    }
}

/// The flags as last read. Empty, so every flag off, until the first
/// successful fetch.
#[derive(Default)]
struct Snapshot {
    flags: RwLock<HashMap<String, bool>>,
}

impl FlagSource for Snapshot {
    fn enabled(&self, name: &str) -> bool {
        self.flags
            .read()
            .map(|flags| flags.get(name).copied().unwrap_or(false))
            .unwrap_or(false)
    }
}

/// The part of the environment document the service reads.
#[derive(Deserialize)]
struct EnvironmentDocument {
    feature_states: Vec<FeatureState>,
}

#[derive(Deserialize)]
struct FeatureState {
    feature: Feature,
    enabled: bool,
}

#[derive(Deserialize)]
struct Feature {
    name: String,
}

/// The on/off state of each flag in an environment document.
pub fn parse_document(body: &str) -> Result<HashMap<String, bool>, serde_json::Error> {
    let document: EnvironmentDocument = serde_json::from_str(body)?;
    Ok(document
        .feature_states
        .into_iter()
        .map(|state| (state.feature.name, state.enabled))
        .collect())
}

/// Builds a source from FLAGSMITH_SERVER_KEY and FLAGSMITH_API_URL.
pub fn from_env() -> Arc<dyn FlagSource> {
    new(
        std::env::var("FLAGSMITH_SERVER_KEY").unwrap_or_default(),
        std::env::var("FLAGSMITH_API_URL").unwrap_or_default(),
    )
}

/// Builds a source that polls `api_url` with `key`. Flagsmith serves the
/// environment document only to a server-side key, so an empty or
/// client-side key is answered with Off without a request.
pub fn new(key: String, api_url: String) -> Arc<dyn FlagSource> {
    if key.is_empty() {
        eprintln!("flags: FLAGSMITH_SERVER_KEY is not set, every feature flag reads as off");
        return Arc::new(Off);
    }
    if !key.starts_with("ser.") {
        eprintln!(
            "flags: FLAGSMITH_SERVER_KEY is not a server-side key (ser.), every feature flag reads as off"
        );
        return Arc::new(Off);
    }
    let mut api_url = if api_url.is_empty() {
        DEFAULT_API_URL.to_string()
    } else {
        api_url
    };
    if !api_url.ends_with('/') {
        api_url.push('/');
    }
    let url = format!("{api_url}environment-document/");

    eprintln!(
        "flags: reading feature flags from {}, refreshed every {}s",
        url,
        REFRESH_INTERVAL.as_secs()
    );
    let snapshot = Arc::new(Snapshot::default());
    let writer = Arc::clone(&snapshot);
    match thread::Builder::new()
        .name("flagsmith".to_string())
        .spawn(move || poll(key, url, writer))
    {
        Ok(_) => snapshot,
        Err(e) => {
            eprintln!("flags: could not start the Flagsmith thread ({e}), every feature flag reads as off");
            Arc::new(Off)
        }
    }
}

/// Fetches the document and updates the snapshot, forever. A failed fetch
/// keeps the last flags.
fn poll(key: String, url: String, snapshot: Arc<Snapshot>) {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(REQUEST_TIMEOUT))
        .build()
        .into();
    loop {
        match fetch(&agent, &url, &key) {
            Ok(flags) => {
                if let Ok(mut current) = snapshot.flags.write() {
                    *current = flags;
                }
            }
            Err(e) => eprintln!(
                "flags: could not read the environment document ({e}), keeping the last flags"
            ),
        }
        thread::sleep(REFRESH_INTERVAL);
    }
}

fn fetch(
    agent: &ureq::Agent,
    url: &str,
    key: &str,
) -> Result<HashMap<String, bool>, Box<dyn std::error::Error>> {
    let body = agent
        .get(url)
        .header("X-Environment-Key", key)
        .call()?
        .body_mut()
        .read_to_string()?;
    Ok(parse_document(&body)?)
}

/// The region an item's warehouse is in. A warehouse with no known region
/// gets none, and so no region field.
pub fn region_for(warehouse: &str) -> Option<&'static str> {
    match warehouse {
        "east" => Some("us-east"),
        "west" => Some("eu-west"),
        _ => None,
    }
}
