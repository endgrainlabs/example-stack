// go-grpc is the pricing and echo service of the example stack: it prices
// items for go-api and answers echo and health calls.
package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"runtime/debug"
	"strings"
	"time"

	"hash/fnv"
	"math"

	pb "github.com/endgrainlabs/example-stack/go-grpc/proto/echopb"
	ppb "github.com/endgrainlabs/example-stack/go-grpc/proto/pricingpb"
	"github.com/grpc-ecosystem/go-grpc-middleware/v2/interceptors/recovery"
	grpcprom "github.com/grpc-ecosystem/go-grpc-prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/reflection"
	"google.golang.org/grpc/status"
)

var (
	startTime time.Time
	apiToken  string
	// Currency rules read once at startup. Empty means every price is USD.
	pricingRules []pricingRule
)

// pricingRule quotes items whose identifier ends in suffix in currency.
// The suffix is the whole of what this service knows about an item: it holds
// no inventory of its own, so it cannot key on anything but the identifier.
type pricingRule struct {
	suffix   string
	currency string
}

// parsePricingRules reads REGIONAL_PRICING: a comma-separated list of
// SUFFIX=CURRENCY rules, for example "002=EUR". Malformed entries are logged
// and skipped so one bad rule cannot stop the service from starting.
func parsePricingRules(spec string) []pricingRule {
	var rules []pricingRule
	for _, entry := range strings.Split(spec, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		suffix, currency, found := strings.Cut(entry, "=")
		suffix = strings.TrimSpace(suffix)
		currency = strings.TrimSpace(currency)
		if !found || suffix == "" || currency == "" {
			log.Printf("ignoring malformed REGIONAL_PRICING rule %q", entry)
			continue
		}
		rules = append(rules, pricingRule{suffix: suffix, currency: currency})
	}
	return rules
}

// currencyFor returns the currency for an item identifier: the first matching
// rule, or USD when none matches.
func currencyFor(rules []pricingRule, itemID string) string {
	for _, r := range rules {
		if strings.HasSuffix(itemID, r.suffix) {
			return r.currency
		}
	}
	return "USD"
}

type echoServer struct {
	pb.UnimplementedEchoServiceServer
}

func (s *echoServer) Echo(ctx context.Context, req *pb.EchoRequest) (*pb.EchoResponse, error) {
	if err := checkAuth(ctx); err != nil {
		return nil, err
	}
	if req.Message == "" {
		return nil, status.Error(codes.InvalidArgument, "message is required")
	}
	return &pb.EchoResponse{
		Message:    req.Message,
		ReceivedAt: time.Now().UTC().Format(time.RFC3339),
	}, nil
}

func (s *echoServer) Health(ctx context.Context, req *pb.HealthRequest) (*pb.HealthResponse, error) {
	return &pb.HealthResponse{
		Status: "SERVING",
		Uptime: time.Since(startTime).String(),
	}, nil
}

type pricingServer struct {
	ppb.UnimplementedPricingServiceServer
}

func (s *pricingServer) GetPrice(ctx context.Context, req *ppb.PriceRequest) (*ppb.PriceResponse, error) {
	if err := checkAuth(ctx); err != nil {
		return nil, err
	}
	if req.ItemId == "" {
		return nil, status.Error(codes.InvalidArgument, "item_id is required")
	}
	if req.Quantity <= 0 {
		return nil, status.Error(codes.InvalidArgument, "quantity must be positive")
	}

	unitPrice := deterministicPrice(req.ItemId)
	total := unitPrice * float64(req.Quantity)

	return &ppb.PriceResponse{
		ItemId:    req.ItemId,
		Quantity:  req.Quantity,
		UnitPrice: unitPrice,
		Total:     total,
		Currency:  currencyFor(pricingRules, req.ItemId),
	}, nil
}

// deterministicPrice generates a stable price from an item ID.
// Hash-based so the same item always gets the same price.
func deterministicPrice(itemID string) float64 {
	h := fnv.New64a()
	h.Write([]byte(itemID))
	// Price between $1.00 and $99.99, rounded to cents
	raw := float64(h.Sum64()%10000) / 100.0
	return math.Max(1.00, raw)
}

func checkAuth(ctx context.Context) error {
	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		return status.Error(codes.Unauthenticated, "missing metadata")
	}
	tokens := md.Get("authorization")
	if len(tokens) == 0 || tokens[0] != "Bearer "+apiToken {
		return status.Error(codes.Unauthenticated, "invalid token")
	}
	return nil
}

// recoverPanic turns a panic in a handler into an Internal error for that
// request, with the stack in the log, so a bug reached through a request
// shows up as an error rate rather than as a restarted process. The client
// gets no detail: the stack is for the operator.
func recoverPanic(p any) error {
	log.Printf("panic in handler: %v\n%s", p, debug.Stack())
	return status.Error(codes.Internal, "internal error")
}

func main() {
	startTime = time.Now()

	apiToken = os.Getenv("API_TOKEN")
	if apiToken == "" {
		apiToken = "dev-token"
	}

	pricingRules = parsePricingRules(os.Getenv("REGIONAL_PRICING"))
	for _, r := range pricingRules {
		log.Printf("pricing items ending in %q in %s", r.suffix, r.currency)
	}

	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":9090"
	}

	metricsAddr := os.Getenv("METRICS_ADDR")
	if metricsAddr == "" {
		metricsAddr = ":9091"
	}

	grpcprom.EnableHandlingTimeHistogram()

	lis, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal(fmt.Errorf("listen: %w", err))
	}

	// Prometheus outermost so a recovered panic is counted as the Internal
	// error it becomes, not as a request that never finished.
	srv := grpc.NewServer(
		grpc.ChainUnaryInterceptor(
			grpcprom.UnaryServerInterceptor,
			recovery.UnaryServerInterceptor(recovery.WithRecoveryHandler(recoverPanic)),
		),
		grpc.ChainStreamInterceptor(
			grpcprom.StreamServerInterceptor,
			recovery.StreamServerInterceptor(recovery.WithRecoveryHandler(recoverPanic)),
		),
	)
	pb.RegisterEchoServiceServer(srv, &echoServer{})
	ppb.RegisterPricingServiceServer(srv, &pricingServer{})
	reflection.Register(srv)
	grpcprom.Register(srv)

	go func() {
		mux := http.NewServeMux()
		mux.Handle("/metrics", promhttp.Handler())
		log.Printf("go-grpc metrics listening on %s", metricsAddr)
		// Plain HTTP by design: a metrics endpoint scraped by Prometheus
		// inside the cluster, with TLS terminating at the ingress.
		// nosemgrep: go.lang.security.audit.net.use-tls.use-tls
		if err := http.ListenAndServe(metricsAddr, mux); err != nil {
			log.Fatalf("metrics server: %v", err)
		}
	}()

	log.Printf("go-grpc listening on %s", addr)
	log.Fatal(srv.Serve(lis))
}
