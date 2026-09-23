use actix_web::{web, App, HttpRequest, HttpResponse, HttpServer};
use actix_web_prom::PrometheusMetricsBuilder;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::{Mutex, MutexGuard};
use tokio_postgres::{Client, NoTls};

mod db;
#[cfg(test)]
mod flag_tests;
mod flags;
#[cfg(test)]
mod tests;

#[derive(Debug, Serialize, Deserialize)]
struct InventoryItem {
    id: String,
    name: String,
    quantity: i32,
    warehouse: String,
    created_at: String,
    /// Present only while inventory.expose_region is on, so with the flag off
    /// a response is byte for byte what it was before the flag existed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    region: Option<String>,
}

impl InventoryItem {
    /// An item as the list and get responses carry it: with its warehouse's
    /// region while inventory.expose_region is on.
    fn listed(
        id: String,
        name: String,
        quantity: i32,
        warehouse: String,
        created_at: String,
        source: &dyn flags::FlagSource,
    ) -> Self {
        let region = if source.enabled(flags::EXPOSE_REGION) {
            flags::region_for(&warehouse).map(str::to_string)
        } else {
            None
        };
        InventoryItem {
            id,
            name,
            quantity,
            warehouse,
            created_at,
            region,
        }
    }
}

#[derive(Debug, Deserialize)]
struct CreateItemRequest {
    name: String,
    quantity: i32,
    warehouse: String,
}

/// The client is optional because a process can be without one: the readiness
/// probe drops it when a reconnect fails, and a test holds this state with
/// none at all.
struct AppState {
    db: Mutex<Option<Client>>,
    db_url: String,
    api_token: String,
    flags: Arc<dyn flags::FlagSource>,
}

impl AppState {
    /// Runs SELECT 1, and on failure rebuilds the client once and tries again.
    /// A readiness probe is therefore what recovers the service after the
    /// database restarts, instead of a pod restart.
    async fn probe(&self) -> bool {
        let mut client = self.db.lock().await;
        if let Some(current) = client.as_ref() {
            if current.simple_query("SELECT 1").await.is_ok() {
                return true;
            }
        }
        match connect(&self.db_url).await {
            Ok(fresh) => {
                let alive = fresh.simple_query("SELECT 1").await.is_ok();
                *client = Some(fresh);
                alive
            }
            Err(e) => {
                eprintln!("Reconnect failed: {}", e);
                *client = None;
                false
            }
        }
    }
}

/// Borrows the client out of a held lock, or answers for a process that has
/// none. The caller keeps the guard: the borrow lives as long as it does.
/// The error is boxed because an HttpResponse is 128 bytes as of actix-web
/// 4.15, and clippy's result_large_err rejects an Err that size.
fn client<'a>(guard: &'a MutexGuard<'_, Option<Client>>) -> Result<&'a Client, Box<HttpResponse>> {
    guard.as_ref().ok_or_else(|| {
        Box::new(
            HttpResponse::ServiceUnavailable()
                .json(serde_json::json!({"error": "database not connected"})),
        )
    })
}

/// tokio-postgres splits a connection into a client and a task that drives it.
/// Once that task ends the client is dead for good and every query on it
/// fails, so recovering means building a new client.
async fn connect(db_url: &str) -> Result<Client, tokio_postgres::Error> {
    let (client, connection) = tokio_postgres::connect(db_url, NoTls).await?;
    tokio::spawn(async move {
        if let Err(e) = connection.await {
            eprintln!("Database connection error: {}", e);
        }
    });
    Ok(client)
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let db_url = std::env::var("DATABASE_URL").unwrap_or_else(|_| {
        "host=localhost user=postgres password=postgres dbname=inventory".to_string()
    });
    let api_token = std::env::var("API_TOKEN").unwrap_or_else(|_| "dev-token".to_string());
    let listen_addr = std::env::var("LISTEN_ADDR").unwrap_or_else(|_| "0.0.0.0:8081".to_string());

    // Retry connection with backoff - migration jobs may not have run yet.
    let mut client_opt = None;
    for attempt in 1..=30 {
        match connect(&db_url).await {
            Ok(client) => match db::check_table(&client).await {
                Ok(_) => {
                    client_opt = Some(client);
                    break;
                }
                Err(e) => {
                    eprintln!("Attempt {}/30: inventory table not ready: {}", attempt, e);
                }
            },
            Err(e) => {
                eprintln!("Attempt {}/30: database not ready: {}", attempt, e);
            }
        }
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
    let client = client_opt.expect("Failed to connect to database after 30 attempts");

    let state = Arc::new(AppState {
        db: Mutex::new(Some(client)),
        db_url,
        api_token,
        flags: flags::from_env(),
    });

    println!("rust-inventory listening on {}", listen_addr);

    let prometheus = PrometheusMetricsBuilder::new("rustinventory")
        .endpoint("/metrics")
        .build()
        .expect("failed to build prometheus middleware");

    HttpServer::new(move || {
        App::new()
            .wrap(prometheus.clone())
            .app_data(web::Data::new(state.clone()))
            .configure(routes)
    })
    .bind(&listen_addr)?
    .run()
    .await
}

/// The routes, in one place, so the server and the tests wire the same ones.
fn routes(cfg: &mut web::ServiceConfig) {
    cfg.route("/healthz", web::get().to(health))
        .route("/readyz", web::get().to(ready))
        .service(
            web::scope("/api/v1")
                .route("/inventory", web::get().to(list_items))
                .route("/inventory", web::post().to(create_item))
                .route("/inventory/{id}", web::get().to(get_item))
                .route("/inventory/{id}", web::delete().to(delete_item)),
        );
}

async fn health() -> HttpResponse {
    HttpResponse::Ok().json(serde_json::json!({"status": "ok"}))
}

async fn ready(state: web::Data<Arc<AppState>>) -> HttpResponse {
    if state.probe().await {
        HttpResponse::Ok().json(serde_json::json!({"status": "ready", "database": "connected"}))
    } else {
        HttpResponse::ServiceUnavailable()
            .json(serde_json::json!({"status": "not ready", "database": "disconnected"}))
    }
}

fn check_auth(req: &HttpRequest, state: &AppState) -> Result<(), Box<HttpResponse>> {
    let token = req
        .headers()
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");

    if token != format!("Bearer {}", state.api_token) {
        return Err(Box::new(
            HttpResponse::Unauthorized().json(serde_json::json!({"error": "unauthorized"})),
        ));
    }
    Ok(())
}

async fn list_items(req: HttpRequest, state: web::Data<Arc<AppState>>) -> HttpResponse {
    if let Err(resp) = check_auth(&req, &state) {
        return *resp;
    }

    let guard = state.db.lock().await;
    let db = match client(&guard) {
        Ok(db) => db,
        Err(resp) => return *resp,
    };
    match db.query("SELECT id, name, quantity, warehouse, created_at FROM inventory ORDER BY created_at DESC", &[]).await {
        Ok(rows) => {
            let items: Vec<InventoryItem> = rows.iter().map(|row| {
                let id: uuid::Uuid = row.get(0);
                let created_at: chrono::NaiveDateTime = row.get(4);
                InventoryItem::listed(
                    id.to_string(),
                    row.get(1),
                    row.get(2),
                    row.get(3),
                    created_at.to_string(),
                    state.flags.as_ref(),
                )
            }).collect();
            HttpResponse::Ok().json(serde_json::json!({"items": items, "count": items.len()}))
        }
        Err(e) => HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()})),
    }
}

async fn create_item(
    req: HttpRequest,
    state: web::Data<Arc<AppState>>,
    body: web::Json<CreateItemRequest>,
) -> HttpResponse {
    if let Err(resp) = check_auth(&req, &state) {
        return *resp;
    }

    if body.name.is_empty() {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "name is required"}));
    }
    if body.quantity < 0 {
        return HttpResponse::BadRequest()
            .json(serde_json::json!({"error": "quantity must be non-negative"}));
    }

    let id = uuid::Uuid::new_v4();
    let guard = state.db.lock().await;
    let db = match client(&guard) {
        Ok(db) => db,
        Err(resp) => return *resp,
    };
    match db
        .execute(
            "INSERT INTO inventory (id, name, quantity, warehouse) VALUES ($1, $2, $3, $4)",
            &[&id, &body.name, &body.quantity, &body.warehouse],
        )
        .await
    {
        Ok(_) => {
            // Fetch back to get created_at
            match db
                .query_one("SELECT created_at FROM inventory WHERE id = $1", &[&id])
                .await
            {
                Ok(row) => {
                    let created_at: chrono::NaiveDateTime = row.get(0);
                    HttpResponse::Created().json(InventoryItem {
                        id: id.to_string(),
                        name: body.name.clone(),
                        quantity: body.quantity,
                        warehouse: body.warehouse.clone(),
                        created_at: created_at.to_string(),
                        region: None,
                    })
                }
                Err(e) => HttpResponse::InternalServerError()
                    .json(serde_json::json!({"error": e.to_string()})),
            }
        }
        Err(e) => {
            HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()}))
        }
    }
}

async fn get_item(
    req: HttpRequest,
    state: web::Data<Arc<AppState>>,
    path: web::Path<String>,
) -> HttpResponse {
    if let Err(resp) = check_auth(&req, &state) {
        return *resp;
    }

    let id = match uuid::Uuid::parse_str(&path.into_inner()) {
        Ok(id) => id,
        Err(_) => {
            return HttpResponse::BadRequest().json(serde_json::json!({"error": "invalid id"}))
        }
    };

    let guard = state.db.lock().await;
    let db = match client(&guard) {
        Ok(db) => db,
        Err(resp) => return *resp,
    };
    match db
        .query_opt(
            "SELECT id, name, quantity, warehouse, created_at FROM inventory WHERE id = $1",
            &[&id],
        )
        .await
    {
        Ok(Some(row)) => {
            let created_at: chrono::NaiveDateTime = row.get(4);
            HttpResponse::Ok().json(InventoryItem::listed(
                id.to_string(),
                row.get(1),
                row.get(2),
                row.get(3),
                created_at.to_string(),
                state.flags.as_ref(),
            ))
        }
        Ok(None) => HttpResponse::NotFound().json(serde_json::json!({"error": "not found"})),
        Err(e) => {
            HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()}))
        }
    }
}

async fn delete_item(
    req: HttpRequest,
    state: web::Data<Arc<AppState>>,
    path: web::Path<String>,
) -> HttpResponse {
    if let Err(resp) = check_auth(&req, &state) {
        return *resp;
    }

    let id = match uuid::Uuid::parse_str(&path.into_inner()) {
        Ok(id) => id,
        Err(_) => {
            return HttpResponse::BadRequest().json(serde_json::json!({"error": "invalid id"}))
        }
    };

    let guard = state.db.lock().await;
    let db = match client(&guard) {
        Ok(db) => db,
        Err(resp) => return *resp,
    };
    match db
        .execute("DELETE FROM inventory WHERE id = $1", &[&id])
        .await
    {
        Ok(0) => HttpResponse::NotFound().json(serde_json::json!({"error": "not found"})),
        Ok(_) => HttpResponse::NoContent().finish(),
        Err(e) => {
            HttpResponse::InternalServerError().json(serde_json::json!({"error": e.to_string()}))
        }
    }
}
