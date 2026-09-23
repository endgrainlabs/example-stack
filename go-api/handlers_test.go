package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	ppb "github.com/endgrainlabs/example-stack/go-grpc/proto/pricingpb"
	"github.com/endgrainlabs/example-stack/internal/flags"
)

const testToken = "test-token"

// fakePricing stands in for the go-grpc client. The client is an interface in
// the generated code, so the handler calls it exactly as it calls the real one.
type fakePricing struct {
	unitPrice float64
	currency  string
	err       error
	last      *ppb.PriceRequest
	lastCtx   context.Context
}

func (f *fakePricing) GetPrice(ctx context.Context, in *ppb.PriceRequest, _ ...grpc.CallOption) (*ppb.PriceResponse, error) {
	f.last = in
	f.lastCtx = ctx
	if f.err != nil {
		return nil, f.err
	}
	return &ppb.PriceResponse{
		ItemId:    in.ItemId,
		Quantity:  in.Quantity,
		UnitPrice: f.unitPrice,
		Total:     f.unitPrice * float64(in.Quantity),
		Currency:  f.currency,
	}, nil
}

type harness struct {
	app       *app
	router    http.Handler
	db        *fakeDB
	pricing   *fakePricing
	inventory *httptest.Server
	// inventoryHandler answers the inventory lookup. Tests replace it.
	inventoryHandler http.HandlerFunc
}

func newHarness(t *testing.T) *harness {
	t.Helper()

	h := &harness{
		db:      &fakeDB{},
		pricing: &fakePricing{unitPrice: 9.99, currency: "USD"},
	}
	h.inventoryHandler = func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+testToken {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		writeJSON(w, http.StatusOK, InventoryItem{
			ID: strings.TrimPrefix(r.URL.Path, "/api/v1/inventory/"), Name: "Widget",
			Quantity: 10, Warehouse: "east", CreatedAt: "2026-09-10T12:00:00Z",
		})
	}
	h.inventory = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h.inventoryHandler(w, r)
	}))
	t.Cleanup(h.inventory.Close)

	db := openFakeDB(h.db)
	t.Cleanup(func() { db.Close() })

	h.app = &app{
		db:           db,
		pricing:      h.pricing,
		inventoryURL: h.inventory.URL,
		httpClient:   &http.Client{Timeout: 2 * time.Second},
		apiToken:     testToken,
	}
	h.router = newRouter(h.app)
	return h
}

// do sends a request through the router with a valid token unless the test
// passes one of its own.
func (h *harness) do(method, path, body string, token *string) *httptest.ResponseRecorder {
	var r *http.Request
	if body == "" {
		r = httptest.NewRequest(method, path, nil)
	} else {
		r = httptest.NewRequest(method, path, strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
	}
	if token == nil {
		r.Header.Set("Authorization", "Bearer "+testToken)
	} else if *token != "" {
		r.Header.Set("Authorization", *token)
	}
	w := httptest.NewRecorder()
	h.router.ServeHTTP(w, r)
	return w
}

const orderBody = `{"item_id":"a0000000-0000-0000-0000-000000000001","quantity":2}`

// metricValue reads one counter series from the /metrics endpoint the service
// exposes, which is where Prometheus reads it. A series that has not been
// touched yet is absent, and absent counts as zero.
func (h *harness) metricValue(t *testing.T, series string) float64 {
	t.Helper()

	w := httptest.NewRecorder()
	h.router.ServeHTTP(w, httptest.NewRequest("GET", "/metrics", nil))
	if w.Code != http.StatusOK {
		t.Fatalf("GET /metrics: status = %d, want 200", w.Code)
	}
	for _, line := range strings.Split(w.Body.String(), "\n") {
		if !strings.HasPrefix(line, series+" ") {
			continue
		}
		v, err := strconv.ParseFloat(strings.TrimSpace(strings.TrimPrefix(line, series)), 64)
		if err != nil {
			t.Fatalf("parse %q: %v", line, err)
		}
		return v
	}
	return 0
}

func TestAuthRejectsMissingAndWrongToken(t *testing.T) {
	h := newHarness(t)

	none := ""
	if w := h.do("GET", "/api/v1/orders", "", &none); w.Code != http.StatusUnauthorized {
		t.Errorf("no token: status = %d, want 401", w.Code)
	}
	wrong := "Bearer not-the-token"
	if w := h.do("POST", "/api/v1/orders", orderBody, &wrong); w.Code != http.StatusUnauthorized {
		t.Errorf("wrong token: status = %d, want 401", w.Code)
	}
	// The health endpoints sit outside the authenticated subrouter.
	if w := h.do("GET", "/healthz", "", &none); w.Code != http.StatusOK {
		t.Errorf("healthz without a token: status = %d, want 200", w.Code)
	}
}

func TestCreateOrderInsufficientStock(t *testing.T) {
	h := newHarness(t)
	h.inventoryHandler = func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, InventoryItem{ID: "a1", Name: "Widget", Quantity: 1, Warehouse: "east"})
	}

	w := h.do("POST", "/api/v1/orders", orderBody, nil)
	if w.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409", w.Code)
	}
	if !strings.Contains(w.Body.String(), "insufficient stock") {
		t.Errorf("body = %q, want an insufficient stock error", w.Body.String())
	}
	if len(h.db.inserted) != 0 {
		t.Errorf("order stored despite insufficient stock")
	}
}

func TestCreateOrderRejectsNonUSDPrice(t *testing.T) {
	h := newHarness(t)
	h.pricing.currency = "EUR"

	w := h.do("POST", "/api/v1/orders", orderBody, nil)
	if w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422", w.Code)
	}
	if !strings.Contains(w.Body.String(), "unsupported currency: EUR") {
		t.Errorf("body = %q, want the unsupported currency error", w.Body.String())
	}
	if len(h.db.inserted) != 0 {
		t.Errorf("order stored despite an unsupported currency")
	}
}

func TestCreateOrderUnreachableBackendsReturn502(t *testing.T) {
	t.Run("inventory", func(t *testing.T) {
		h := newHarness(t)
		// Nothing is listening once the server is closed, which is the shape
		// of an inventory pod that is gone or a Service that routes nowhere.
		h.inventory.Close()

		w := h.do("POST", "/api/v1/orders", orderBody, nil)
		if w.Code != http.StatusBadGateway {
			t.Fatalf("status = %d, want 502", w.Code)
		}
		if !strings.Contains(w.Body.String(), "inventory lookup failed") {
			t.Errorf("body = %q, want the inventory lookup error", w.Body.String())
		}
	})

	t.Run("pricing", func(t *testing.T) {
		h := newHarness(t)
		h.pricing.err = status.Error(codes.Unavailable, "connection refused")

		w := h.do("POST", "/api/v1/orders", orderBody, nil)
		if w.Code != http.StatusBadGateway {
			t.Fatalf("status = %d, want 502", w.Code)
		}
		if !strings.Contains(w.Body.String(), "pricing lookup failed") {
			t.Errorf("body = %q, want the pricing lookup error", w.Body.String())
		}
	})
}

func TestCreateOrderSuccess(t *testing.T) {
	h := newHarness(t)

	w := h.do("POST", "/api/v1/orders", orderBody, nil)
	if w.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201 (body %q)", w.Code, w.Body.String())
	}
	if got := w.Header().Get("Content-Type"); got != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", got)
	}

	var o Order
	if err := json.Unmarshal(w.Body.Bytes(), &o); err != nil {
		t.Fatalf("decode body: %v (body %q)", err, w.Body.String())
	}
	if _, err := uuid.Parse(o.ID); err != nil {
		t.Errorf("id = %q, want a UUID", o.ID)
	}
	if o.ItemID != "a0000000-0000-0000-0000-000000000001" || o.ItemName != "Widget" || o.Warehouse != "east" {
		t.Errorf("order composed from the wrong item: %+v", o)
	}
	if o.Quantity != 2 || o.UnitPrice != 9.99 || o.Total != 19.98 || o.Currency != "USD" {
		t.Errorf("order priced wrong: %+v", o)
	}
	if _, err := time.Parse(time.RFC3339, o.CreatedAt); err != nil {
		t.Errorf("created_at = %q, want RFC3339", o.CreatedAt)
	}
	if h.pricing.last.GetQuantity() != 2 || h.pricing.last.GetItemId() != o.ItemID {
		t.Errorf("pricing asked for %+v, want the requested item and quantity", h.pricing.last)
	}
	if _, ok := h.pricing.lastCtx.Deadline(); !ok {
		t.Error("pricing call carried no deadline")
	}
	if len(h.db.inserted) != 1 {
		t.Fatalf("stored %d orders, want 1", len(h.db.inserted))
	}
	if got := h.db.inserted[0][1]; got != o.ItemID {
		t.Errorf("stored item_id = %v, want %s", got, o.ItemID)
	}
}

func TestListOrders(t *testing.T) {
	h := newHarness(t)
	h.db.orders = []Order{{
		ID: "1f6dc86f-9a3f-4c0b-9c27-3b1d6d5a0f01", ItemID: "a1", ItemName: "Widget",
		Quantity: 2, UnitPrice: 9.99, Total: 19.98, Currency: "USD", Warehouse: "east",
		CreatedAt: "2026-09-10T12:00:00Z",
	}}

	w := h.do("GET", "/api/v1/orders", "", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body %q)", w.Code, w.Body.String())
	}
	var body struct {
		Orders []Order `json:"orders"`
		Count  int     `json:"count"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode body: %v (body %q)", err, w.Body.String())
	}
	if body.Count != 1 || len(body.Orders) != 1 {
		t.Fatalf("count = %d with %d orders, want 1 and 1", body.Count, len(body.Orders))
	}
	if body.Orders[0] != h.db.orders[0] {
		t.Errorf("order = %+v, want %+v", body.Orders[0], h.db.orders[0])
	}
}

// An empty list is an empty array, not null: the UI iterates it.
func TestListOrdersEmpty(t *testing.T) {
	h := newHarness(t)

	w := h.do("GET", "/api/v1/orders", "", nil)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
	if got := strings.TrimSpace(w.Body.String()); got != `{"count":0,"orders":[]}` {
		t.Errorf("body = %s, want an empty orders array", got)
	}
}

// A read that fails after the first row is an error, not a short list.
func TestListOrdersReadFailsPartway(t *testing.T) {
	h := newHarness(t)
	h.db.orders = []Order{{ID: "1f6dc86f-9a3f-4c0b-9c27-3b1d6d5a0f01", CreatedAt: "2026-09-10T12:00:00Z"}}
	h.db.listErr = errFakeQuery

	w := h.do("GET", "/api/v1/orders", "", nil)
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500 (body %q)", w.Code, w.Body.String())
	}
}

// A request that matches no route is counted under a fixed label, so the
// counter cannot be given new series by whatever path a client sends.
func TestUnmatchedRequestsShareOneRouteLabel(t *testing.T) {
	h := newHarness(t)

	const unmatched = `goapi_http_requests_total{method="GET",route="unmatched",status="404"}`

	before := h.metricValue(t, unmatched)
	for _, path := range []string{"/nope", "/also-nope"} {
		if w := h.do("GET", path, "", nil); w.Code != http.StatusNotFound {
			t.Fatalf("%s: status = %d, want 404", path, w.Code)
		}
	}
	if got := h.metricValue(t, unmatched) - before; got != 2 {
		t.Errorf("unmatched counter rose by %v, want 2", got)
	}
	if got := h.metricValue(t, `goapi_http_requests_total{method="GET",route="/nope",status="404"}`); got != 0 {
		t.Errorf("a series exists for the requested path: %v", got)
	}

	// A known path with the wrong method matches no route either.
	const wrongMethod = `goapi_http_requests_total{method="POST",route="unmatched",status="405"}`
	before405 := h.metricValue(t, wrongMethod)
	if w := h.do("POST", "/healthz", "", nil); w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST /healthz: status = %d, want 405", w.Code)
	}
	if got := h.metricValue(t, wrongMethod) - before405; got != 1 {
		t.Errorf("method mismatch counter rose by %v, want 1", got)
	}
}

// The route label on a matched request is the template, so orders for
// different identifiers share one series.
func TestMatchedRequestsAreLabeledWithTheRouteTemplate(t *testing.T) {
	h := newHarness(t)

	const listed = `goapi_http_requests_total{method="GET",route="/api/v1/orders",status="200"}`

	before := h.metricValue(t, listed)
	if w := h.do("GET", "/api/v1/orders", "", nil); w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
	if got := h.metricValue(t, listed) - before; got != 1 {
		t.Errorf("counter rose by %v, want 1", got)
	}
}

// A write that fails is a 500, and the response says nothing about the
// database error.
func TestCreateOrderStoreFails(t *testing.T) {
	h := newHarness(t)
	h.db.failOn = "INSERT INTO orders"

	w := h.do("POST", "/api/v1/orders", orderBody, nil)
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500 (body %q)", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "failed to create order") {
		t.Errorf("body = %q, want the generic create failure", w.Body.String())
	}
}

// Readiness follows the database: the probe is what takes a pod out of the
// Service when its database is gone.
func TestReadyFollowsTheDatabase(t *testing.T) {
	h := newHarness(t)
	none := ""

	if w := h.do("GET", "/readyz", "", &none); w.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", w.Code)
	}
	h.db.pingErr = errFakeQuery
	w := h.do("GET", "/readyz", "", &none)
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", w.Code)
	}
	if !strings.Contains(w.Body.String(), "disconnected") {
		t.Errorf("body = %q, want the disconnected database", w.Body.String())
	}
}

// fakeFlags stands in for the Flagsmith-backed source: the flags named in it
// are on, every other one is off.
type fakeFlags map[string]bool

func (f fakeFlags) Enabled(name string) bool { return f[name] }

// westItem answers the inventory lookup with the west warehouse item, carrying
// the region rust-inventory adds while its inventory.expose_region flag is on.
func westItem(region string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, InventoryItem{
			ID: "a0000000-0000-0000-0000-000000000002", Name: "Gadget",
			Quantity: 50, Warehouse: "west", Region: region, CreatedAt: "2026-09-10T12:00:00Z",
		})
	}
}

// orders.forward_region passes the item's region to pricing, and only while
// it is on and the item carries one.
func TestCreateOrderForwardsRegionOnlyWithTheFlag(t *testing.T) {
	for _, tt := range []struct {
		name   string
		flags  flags.Source
		region string
		want   *string
	}{
		{"flag on, region present", fakeFlags{flagForwardRegion: true}, "eu-west", ptr("eu-west")},
		{"flag on, no region", fakeFlags{flagForwardRegion: true}, "", nil},
		{"flag off, region present", fakeFlags{}, "eu-west", nil},
		{"no Flagsmith key", flags.New(context.Background(), "", ""), "eu-west", nil},
		{"no source at all", nil, "eu-west", nil},
	} {
		t.Run(tt.name, func(t *testing.T) {
			h := newHarness(t)
			h.app.flags = tt.flags
			h.inventoryHandler = westItem(tt.region)

			w := h.do("POST", "/api/v1/orders", orderBody, nil)
			if w.Code != http.StatusCreated {
				t.Fatalf("status = %d, want 201 (body %q)", w.Code, w.Body.String())
			}
			got := h.pricing.last.Region
			switch {
			case tt.want == nil && got != nil:
				t.Errorf("pricing asked with region %q, want none", *got)
			case tt.want != nil && (got == nil || *got != *tt.want):
				t.Errorf("pricing asked with region %v, want %q", got, *tt.want)
			}
		})
	}
}

// The USD check is unchanged: a region that pricing answers in EUR is the
// same 422 an EUR price for any other reason is.
func TestCreateOrderRegionalPriceIsStillRejected(t *testing.T) {
	h := newHarness(t)
	h.app.flags = fakeFlags{flagForwardRegion: true}
	h.inventoryHandler = westItem("eu-west")
	h.pricing.currency = "EUR"

	w := h.do("POST", "/api/v1/orders", orderBody, nil)
	if w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422 (body %q)", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "unsupported currency: EUR") {
		t.Errorf("body = %q, want the unsupported currency error", w.Body.String())
	}
}

func ptr(s string) *string { return &s }
