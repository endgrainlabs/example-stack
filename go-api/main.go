// go-api is the frontend service of the example stack.
// It composes responses from two backends: rust-inventory (HTTP) for stock
// and go-grpc (gRPC) for pricing, and stores orders in PostgreSQL.
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/mux"
	_ "github.com/lib/pq"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"

	ppb "github.com/endgrainlabs/example-stack/go-grpc/proto/pricingpb"
	"github.com/endgrainlabs/example-stack/internal/flags"
)

// Order represents a composed order stored in Postgres.
type Order struct {
	ID        string  `json:"id"`
	ItemID    string  `json:"item_id"`
	ItemName  string  `json:"item_name"`
	Quantity  int32   `json:"quantity"`
	UnitPrice float64 `json:"unit_price"`
	Total     float64 `json:"total"`
	Currency  string  `json:"currency"`
	Warehouse string  `json:"warehouse"`
	CreatedAt string  `json:"created_at"`
}

// InventoryItem is the response shape from rust-inventory. Region is present
// only while rust-inventory's inventory.expose_region flag is on.
type InventoryItem struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Quantity  int32  `json:"quantity"`
	Warehouse string `json:"warehouse"`
	Region    string `json:"region,omitempty"`
	CreatedAt string `json:"created_at"`
}

// flagForwardRegion passes the inventory item's region on to pricing.
const flagForwardRegion = "orders.forward_region"

// backendTimeout bounds every call go-api makes to another service. The
// HTTP client has always carried it; the gRPC client inherits the request
// context, which has no deadline, so the pricing call sets one itself.
const backendTimeout = 5 * time.Second

type app struct {
	db           *sql.DB
	pricing      ppb.PricingServiceClient
	inventoryURL string
	httpClient   *http.Client
	apiToken     string
	flags        flags.Source
}

var (
	httpRequestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "goapi_http_requests_total",
			Help: "Total HTTP requests handled by go-api, labeled by method, route, and status.",
		},
		[]string{"method", "route", "status"},
	)
	httpRequestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "goapi_http_request_duration_seconds",
			Help:    "HTTP request latency in go-api.",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"method", "route"},
	)
	ordersGauge = promauto.NewGauge(
		prometheus.GaugeOpts{
			Name: "goapi_orders_count",
			Help: "Current number of orders in the database.",
		},
	)
)

func main() {
	apiToken := os.Getenv("API_TOKEN")
	if apiToken == "" {
		apiToken = "dev-token"
	}

	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":8080"
	}

	dbDSN := os.Getenv("DATABASE_URL")
	if dbDSN == "" {
		dbDSN = "host=postgres user=postgres password=postgres dbname=orders sslmode=disable"
	}

	grpcAddr := os.Getenv("GRPC_ADDR")
	if grpcAddr == "" {
		grpcAddr = "go-grpc:9090"
	}

	inventoryURL := os.Getenv("INVENTORY_URL")
	if inventoryURL == "" {
		inventoryURL = "http://rust-inventory:8081"
	}

	// Connect to Postgres with retry - migration jobs may not have run yet.
	db, err := sql.Open("postgres", dbDSN)
	if err != nil {
		log.Fatalf("failed to open database: %v", err)
	}
	defer db.Close()

	// Both an unreachable database and a missing table are fatal once the
	// attempts run out: a server that starts without them answers every
	// request with an error and still reports itself live.
	ready := false
	for attempt := 1; attempt <= 30; attempt++ {
		if err := db.Ping(); err != nil {
			log.Printf("attempt %d/30: database not reachable: %v", attempt, err)
			time.Sleep(2 * time.Second)
			continue
		}
		var exists bool
		if err := db.QueryRow("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'orders')").Scan(&exists); err == nil && exists {
			ready = true
			break
		}
		log.Printf("attempt %d/30: orders table not found, waiting for migration job", attempt)
		time.Sleep(2 * time.Second)
	}
	if !ready {
		log.Fatal("database unreachable or orders table missing after 30 attempts - has the migrate job run?")
	}

	// Connect to go-grpc pricing service
	conn, err := grpc.NewClient(grpcAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatalf("failed to connect to pricing service: %v", err)
	}
	defer conn.Close()

	a := &app{
		db:           db,
		pricing:      ppb.NewPricingServiceClient(conn),
		inventoryURL: inventoryURL,
		httpClient:   &http.Client{Timeout: backendTimeout},
		apiToken:     apiToken,
		flags:        flags.FromEnv(context.Background()),
	}

	log.Printf("go-api listening on %s", addr)
	// Plain HTTP by design: the stack's ingress is HTTP-only and the
	// cluster is local. Nothing here carries a credential worth a certificate.
	// nosemgrep: go.lang.security.audit.net.use-tls.use-tls
	log.Fatal(http.ListenAndServe(addr, newRouter(a)))
}

// newRouter wires the routes and the middleware. It is separate from main so
// a test can drive the same routing, authentication, and metrics labeling the
// service runs.
func newRouter(a *app) http.Handler {
	r := mux.NewRouter()
	r.Use(metricsMiddleware)
	// Middleware added with Use runs only for a request that matched a route,
	// so the two fallbacks are wrapped by hand. Without this an unmatched
	// request is counted nowhere and the "unmatched" label never appears.
	r.NotFoundHandler = metricsMiddleware(http.NotFoundHandler())
	r.MethodNotAllowedHandler = metricsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusMethodNotAllowed)
	}))
	r.Handle("/metrics", promhttp.Handler()).Methods("GET")
	r.HandleFunc("/healthz", a.handleHealth).Methods("GET")
	r.HandleFunc("/readyz", a.handleReady).Methods("GET")

	api := r.PathPrefix("/api/v1").Subrouter()
	api.Use(a.authMiddleware)
	api.HandleFunc("/orders", a.handleListOrders).Methods("GET")
	api.HandleFunc("/orders", a.handleCreateOrder).Methods("POST")
	api.HandleFunc("/orders/{id}", a.handleGetOrder).Methods("GET")
	api.HandleFunc("/orders/{id}", a.handleDeleteOrder).Methods("DELETE")

	return r
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (sr *statusRecorder) WriteHeader(code int) {
	sr.status = code
	sr.ResponseWriter.WriteHeader(code)
}

func metricsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/metrics" {
			next.ServeHTTP(w, r)
			return
		}
		start := time.Now()
		sr := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(sr, r)

		// A request that matched no route carries whatever path the client
		// sent, so labeling with it would let anyone mint metric series.
		route := "unmatched"
		if cur := mux.CurrentRoute(r); cur != nil {
			if tpl, err := cur.GetPathTemplate(); err == nil {
				route = tpl
			}
		}
		httpRequestsTotal.WithLabelValues(r.Method, route, strconv.Itoa(sr.status)).Inc()
		httpRequestDuration.WithLabelValues(r.Method, route).Observe(time.Since(start).Seconds())
	})
}

func (a *app) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := r.Header.Get("Authorization")
		if token != "Bearer "+a.apiToken {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (a *app) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (a *app) handleReady(w http.ResponseWriter, r *http.Request) {
	result := map[string]string{"status": "ready"}

	if err := a.db.Ping(); err != nil {
		result["status"] = "not ready"
		result["database"] = "disconnected"
		writeJSON(w, http.StatusServiceUnavailable, result)
		return
	}
	result["database"] = "connected"

	writeJSON(w, http.StatusOK, result)
}

func (a *app) handleCreateOrder(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ItemID   string `json:"item_id"`
		Quantity int32  `json:"quantity"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
		return
	}
	if req.ItemID == "" {
		http.Error(w, `{"error":"item_id is required"}`, http.StatusBadRequest)
		return
	}
	if req.Quantity <= 0 {
		http.Error(w, `{"error":"quantity must be positive"}`, http.StatusBadRequest)
		return
	}

	// Call rust-inventory to validate item exists and check stock
	item, err := a.getInventoryItem(req.ItemID)
	if err != nil {
		log.Printf("inventory lookup failed: %v", err)
		http.Error(w, fmt.Sprintf(`{"error":"inventory lookup failed: %v"}`, err), http.StatusBadGateway)
		return
	}
	if item.Quantity < req.Quantity {
		http.Error(w, fmt.Sprintf(`{"error":"insufficient stock: requested %d, available %d"}`, req.Quantity, item.Quantity), http.StatusConflict)
		return
	}

	// Call go-grpc for pricing
	ctx, cancel := context.WithTimeout(r.Context(), backendTimeout)
	defer cancel()
	ctx = metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+a.apiToken)
	priceReq := &ppb.PriceRequest{
		ItemId:   req.ItemID,
		Quantity: req.Quantity,
	}
	if item.Region != "" && flags.On(a.flags, flagForwardRegion) {
		priceReq.Region = &item.Region
	}
	priceResp, err := a.pricing.GetPrice(ctx, priceReq)
	if err != nil {
		log.Printf("pricing lookup failed: %v", err)
		http.Error(w, fmt.Sprintf(`{"error":"pricing lookup failed: %v"}`, err), http.StatusBadGateway)
		return
	}

	// The orders table stores a currency but every downstream reader assumes
	// USD. The proto allows any currency string, so the check belongs here.
	if priceResp.Currency != "USD" {
		log.Printf("pricing returned unexpected currency %q for item %s", priceResp.Currency, req.ItemID)
		http.Error(w, fmt.Sprintf(`{"error":"unsupported currency: %s"}`, priceResp.Currency), http.StatusUnprocessableEntity)
		return
	}

	// Store order
	orderID := uuid.New()
	var createdAt time.Time
	err = a.db.QueryRowContext(r.Context(),
		`INSERT INTO orders (id, item_id, item_name, quantity, unit_price, total, currency, warehouse)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		 RETURNING created_at`,
		orderID, req.ItemID, item.Name, req.Quantity,
		priceResp.UnitPrice, priceResp.Total, priceResp.Currency, item.Warehouse,
	).Scan(&createdAt)
	if err != nil {
		log.Printf("failed to insert order: %v", err)
		http.Error(w, `{"error":"failed to create order"}`, http.StatusInternalServerError)
		return
	}

	a.updateOrdersGauge()

	writeJSON(w, http.StatusCreated, Order{
		ID:        orderID.String(),
		ItemID:    req.ItemID,
		ItemName:  item.Name,
		Quantity:  req.Quantity,
		UnitPrice: priceResp.UnitPrice,
		Total:     priceResp.Total,
		Currency:  priceResp.Currency,
		Warehouse: item.Warehouse,
		CreatedAt: createdAt.UTC().Format(time.RFC3339),
	})
}

func (a *app) handleListOrders(w http.ResponseWriter, r *http.Request) {
	rows, err := a.db.QueryContext(r.Context(),
		`SELECT id, item_id, item_name, quantity, unit_price, total, currency, warehouse, created_at
		 FROM orders ORDER BY created_at DESC`)
	if err != nil {
		http.Error(w, `{"error":"failed to query orders"}`, http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	orders := make([]Order, 0)
	for rows.Next() {
		var o Order
		var id uuid.UUID
		var createdAt time.Time
		if err := rows.Scan(&id, &o.ItemID, &o.ItemName, &o.Quantity, &o.UnitPrice, &o.Total, &o.Currency, &o.Warehouse, &createdAt); err != nil {
			http.Error(w, `{"error":"failed to scan order"}`, http.StatusInternalServerError)
			return
		}
		o.ID = id.String()
		o.CreatedAt = createdAt.UTC().Format(time.RFC3339)
		orders = append(orders, o)
	}
	// A read that fails partway leaves rows.Next false and a short slice, so
	// the error has to be asked for or the response is a truncated success.
	if err := rows.Err(); err != nil {
		http.Error(w, `{"error":"failed to read orders"}`, http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"orders": orders, "count": len(orders)})
}

func (a *app) handleGetOrder(w http.ResponseWriter, r *http.Request) {
	idStr := mux.Vars(r)["id"]
	id, err := uuid.Parse(idStr)
	if err != nil {
		http.Error(w, `{"error":"invalid id"}`, http.StatusBadRequest)
		return
	}

	var o Order
	var createdAt time.Time
	err = a.db.QueryRowContext(r.Context(),
		`SELECT id, item_id, item_name, quantity, unit_price, total, currency, warehouse, created_at
		 FROM orders WHERE id = $1`, id,
	).Scan(&id, &o.ItemID, &o.ItemName, &o.Quantity, &o.UnitPrice, &o.Total, &o.Currency, &o.Warehouse, &createdAt)
	if err == sql.ErrNoRows {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}
	if err != nil {
		http.Error(w, `{"error":"failed to query order"}`, http.StatusInternalServerError)
		return
	}
	o.ID = id.String()
	o.CreatedAt = createdAt.UTC().Format(time.RFC3339)

	writeJSON(w, http.StatusOK, o)
}

func (a *app) handleDeleteOrder(w http.ResponseWriter, r *http.Request) {
	idStr := mux.Vars(r)["id"]
	id, err := uuid.Parse(idStr)
	if err != nil {
		http.Error(w, `{"error":"invalid id"}`, http.StatusBadRequest)
		return
	}

	result, err := a.db.ExecContext(r.Context(), `DELETE FROM orders WHERE id = $1`, id)
	if err != nil {
		http.Error(w, `{"error":"failed to delete order"}`, http.StatusInternalServerError)
		return
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
		return
	}

	a.updateOrdersGauge()
	w.WriteHeader(http.StatusNoContent)
}

// getInventoryItem calls rust-inventory to fetch an item by ID.
func (a *app) getInventoryItem(itemID string) (*InventoryItem, error) {
	req, err := http.NewRequest("GET", fmt.Sprintf("%s/api/v1/inventory/%s", a.inventoryURL, itemID), nil)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+a.apiToken)

	resp, err := a.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode == http.StatusNotFound {
		return nil, fmt.Errorf("item %s not found in inventory", itemID)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("inventory returned %d: %s", resp.StatusCode, string(body))
	}

	var item InventoryItem
	if err := json.Unmarshal(body, &item); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}
	return &item, nil
}

func (a *app) updateOrdersGauge() {
	var count int64
	if err := a.db.QueryRow("SELECT COUNT(*) FROM orders").Scan(&count); err == nil {
		ordersGauge.Set(float64(count))
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}
