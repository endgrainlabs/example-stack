// Package flags reads the stack's feature flags from Flagsmith for go-api and
// go-grpc. Flags are evaluated locally from the environment document, which
// the SDK fetches with a server-side key and refreshes every ten seconds, so
// a lookup never waits on the network. A service with no key, or one that
// has never reached Flagsmith, reads every flag as off, which is the
// behaviour the stack has without Flagsmith at all.
package flags

import (
	"context"
	"log"
	"log/slog"
	"os"
	"strings"
	"time"

	flagsmith "github.com/Flagsmith/flagsmith-go-client/v4"
)

// DefaultAPIURL is the in-cluster Flagsmith API. Without it the SDK would
// default to Flagsmith's hosted service, outside the cluster.
const DefaultAPIURL = "http://flagsmith.flagsmith.svc.cluster.local:8000/api/v1/"

// RefreshInterval is how often the environment document is fetched again.
const RefreshInterval = 10 * time.Second

// Source answers whether a feature flag is on. The SDK-backed source and the
// tests' fakes both satisfy it.
type Source interface {
	Enabled(name string) bool
}

// Off is the source for a service with no key: every flag is off.
type Off struct{}

// Enabled reports false for every flag.
func (Off) Enabled(string) bool { return false }

// On reports whether src has the flag on. A nil source is off, so a server
// built without one behaves as it did before flags existed.
func On(src Source, name string) bool {
	return src != nil && src.Enabled(name)
}

// FromEnv builds a source from FLAGSMITH_SERVER_KEY and FLAGSMITH_API_URL.
func FromEnv(ctx context.Context) Source {
	return New(ctx, os.Getenv("FLAGSMITH_SERVER_KEY"), os.Getenv("FLAGSMITH_API_URL"))
}

// New builds a source that evaluates flags locally with key, polling apiURL.
// The SDK panics on a key that is not server-side when local evaluation is
// on, so an empty or client-side key is answered with Off instead. The
// polling stops when ctx is done.
func New(ctx context.Context, key, apiURL string) Source {
	if key == "" {
		log.Print("flags: FLAGSMITH_SERVER_KEY is not set, every feature flag reads as off")
		return Off{}
	}
	if !strings.HasPrefix(key, "ser.") {
		log.Print("flags: FLAGSMITH_SERVER_KEY is not a server-side key (ser.), every feature flag reads as off")
		return Off{}
	}
	if apiURL == "" {
		apiURL = DefaultAPIURL
	}
	// The SDK appends endpoint paths to the base URL as they are.
	if !strings.HasSuffix(apiURL, "/") {
		apiURL += "/"
	}
	log.Printf("flags: evaluating feature flags locally from %s, refreshed every %s", apiURL, RefreshInterval)
	client := flagsmith.NewClient(key,
		flagsmith.WithBaseURL(apiURL),
		flagsmith.WithLocalEvaluation(ctx),
		flagsmith.WithEnvironmentRefreshInterval(RefreshInterval),
		// The SDK's own logger is at debug level and logs every poll.
		flagsmith.WithSlogLogger(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))),
	)
	return &sdkSource{client: client}
}

type sdkSource struct {
	client *flagsmith.Client
}

// Enabled reads the last environment document the SDK fetched. Until the
// first fetch succeeds the SDK returns an error, and a flag it does not know
// is an error too; both read as off.
func (s *sdkSource) Enabled(name string) bool {
	f, err := s.client.GetEnvironmentFlags(context.Background())
	if err != nil {
		return false
	}
	on, err := f.IsFeatureEnabled(name)
	return err == nil && on
}
