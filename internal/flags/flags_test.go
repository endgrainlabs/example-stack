package flags

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// A minimal environment document, in the shape Flagsmith serves at
// /api/v1/environment-document/ to a server-side key: one flag on, one off.
const environmentDocument = `{
  "api_key": "client-key",
  "project": {
    "name": "example-stack",
    "organisation": {"id": 1, "name": "example-stack", "feature_analytics": false, "stop_serving_flags": false, "persist_trait_data": true},
    "id": 1,
    "hide_disabled_flags": false,
    "segments": []
  },
  "segment_overrides": [],
  "id": 1,
  "feature_states": [
    {"id": 1, "feature": {"id": 1, "name": "orders.forward_region", "type": "STANDARD"}, "enabled": true, "feature_state_value": null, "multivariate_feature_state_values": []},
    {"id": 2, "feature": {"id": 2, "name": "pricing.regional_currency", "type": "STANDARD"}, "enabled": false, "feature_state_value": null, "multivariate_feature_state_values": []}
  ],
  "identity_overrides": []
}`

func TestNoKeyReadsEveryFlagAsOff(t *testing.T) {
	src := New(context.Background(), "", "")
	if _, ok := src.(Off); !ok {
		t.Fatalf("New with no key = %T, want Off", src)
	}
	if src.Enabled("orders.forward_region") {
		t.Error("a flag is on with no key")
	}
}

// The SDK panics on a client-side key when local evaluation is on; the
// wrapper answers Off instead, so a mistyped Secret does not stop a service.
func TestClientSideKeyReadsEveryFlagAsOff(t *testing.T) {
	src := New(context.Background(), "B62qaMZNwfiqT76p38ggrQ", "")
	if _, ok := src.(Off); !ok {
		t.Fatalf("New with a client-side key = %T, want Off", src)
	}
}

func TestOnTreatsANilSourceAsOff(t *testing.T) {
	if On(nil, "orders.forward_region") {
		t.Error("a nil source reported a flag on")
	}
}

func TestReadsFlagsFromTheEnvironmentDocument(t *testing.T) {
	var mu sync.Mutex
	var sawKey, sawPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		sawKey = r.Header.Get("X-Environment-Key")
		sawPath = r.URL.Path
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(environmentDocument))
	}))
	t.Cleanup(srv.Close)

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	// No trailing slash: New adds the one the SDK needs.
	src := New(ctx, "ser.test-key", srv.URL+"/api/v1")

	// The first fetch runs in the SDK's polling goroutine, right away.
	deadline := time.Now().Add(5 * time.Second)
	for !src.Enabled("orders.forward_region") {
		if time.Now().After(deadline) {
			t.Fatal("orders.forward_region never read as on")
		}
		time.Sleep(20 * time.Millisecond)
	}
	mu.Lock()
	defer mu.Unlock()
	if sawPath != "/api/v1/environment-document/" {
		t.Errorf("fetched %q, want /api/v1/environment-document/", sawPath)
	}
	if sawKey != "ser.test-key" {
		t.Errorf("X-Environment-Key = %q, want the server-side key", sawKey)
	}
	if src.Enabled("pricing.regional_currency") {
		t.Error("a flag that is off in the document read as on")
	}
	if src.Enabled("inventory.expose_region") {
		t.Error("a flag missing from the document read as on")
	}
}

// Flagsmith unreachable at startup is every flag off, not a crash or a hang.
func TestUnreachableFlagsmithReadsEveryFlagAsOff(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	url := srv.URL + "/api/v1/"
	srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	src := New(ctx, "ser.test-key", url)

	for i := 0; i < 10; i++ {
		if src.Enabled("orders.forward_region") {
			t.Fatal("a flag read as on with Flagsmith unreachable")
		}
		time.Sleep(20 * time.Millisecond)
	}
}
