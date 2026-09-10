use tokio_postgres::Client;

/// Checks that the inventory table exists. Migrations are run by the migrate
/// Job before the service starts, so a missing table means the Job has not
/// run yet. Nothing about the columns is checked here: a query that names a
/// column the table no longer has fails on its own, per request.
pub async fn check_table(client: &Client) -> Result<(), tokio_postgres::Error> {
    client
        .batch_execute("SELECT 1 FROM inventory LIMIT 0")
        .await
}
