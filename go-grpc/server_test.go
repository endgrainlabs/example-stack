package main

import (
	"context"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	pb "github.com/endgrainlabs/example-stack/go-grpc/proto/echopb"
	ppb "github.com/endgrainlabs/example-stack/go-grpc/proto/pricingpb"
)

// The seeded inventory identifiers, which the scenarios and the smoke test
// use: item 001 is the east warehouse item, item 002 the west one.
const (
	itemEast = "a0000000-0000-0000-0000-000000000001"
	itemWest = "a0000000-0000-0000-0000-000000000002"
)

// The service reads its token and its pricing rules from package state at
// startup, so a test sets them and puts them back.
func withServiceConfig(t *testing.T, token, regionalPricing string) {
	t.Helper()

	oldToken, oldRules := apiToken, pricingRules
	apiToken = token
	pricingRules = parsePricingRules(regionalPricing)
	t.Cleanup(func() {
		apiToken, pricingRules = oldToken, oldRules
	})
}

func authedContext(token string) context.Context {
	return metadata.NewIncomingContext(context.Background(),
		metadata.Pairs("authorization", "Bearer "+token))
}

func wantCode(t *testing.T, err error, want codes.Code) {
	t.Helper()

	if status.Code(err) != want {
		t.Errorf("error = %v, want code %s", err, want)
	}
}

func TestGetPriceRequiresAToken(t *testing.T) {
	withServiceConfig(t, "test-token", "")
	s := &pricingServer{}
	req := &ppb.PriceRequest{ItemId: itemEast, Quantity: 1}

	// No metadata at all is the shape of a client that never set the header.
	_, err := s.GetPrice(context.Background(), req)
	wantCode(t, err, codes.Unauthenticated)

	_, err = s.GetPrice(authedContext("wrong-token"), req)
	wantCode(t, err, codes.Unauthenticated)

	if _, err := s.GetPrice(authedContext("test-token"), req); err != nil {
		t.Errorf("with the right token: %v", err)
	}
}

func TestGetPriceValidatesTheRequest(t *testing.T) {
	withServiceConfig(t, "test-token", "")
	s := &pricingServer{}
	ctx := authedContext("test-token")

	for _, tt := range []struct {
		name string
		req  *ppb.PriceRequest
	}{
		{"empty item id", &ppb.PriceRequest{ItemId: "", Quantity: 1}},
		{"zero quantity", &ppb.PriceRequest{ItemId: itemEast, Quantity: 0}},
		{"negative quantity", &ppb.PriceRequest{ItemId: itemEast, Quantity: -3}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			_, err := s.GetPrice(ctx, tt.req)
			wantCode(t, err, codes.InvalidArgument)
		})
	}
}

// The price is a hash of the identifier, so it is the same on every pod and
// after every restart. The expected values are the ones this hash produces:
// changing the function changes prices the stack has already quoted.
func TestGetPriceIsDeterministic(t *testing.T) {
	withServiceConfig(t, "test-token", "")
	s := &pricingServer{}
	ctx := authedContext("test-token")

	for _, tt := range []struct {
		itemID string
		want   float64
	}{
		{itemEast, 51.23},
		{itemWest, 33.34},
	} {
		resp, err := s.GetPrice(ctx, &ppb.PriceRequest{ItemId: tt.itemID, Quantity: 3})
		if err != nil {
			t.Fatalf("GetPrice(%s): %v", tt.itemID, err)
		}
		if resp.UnitPrice != tt.want {
			t.Errorf("unit price for %s = %v, want %v", tt.itemID, resp.UnitPrice, tt.want)
		}
		if resp.Total != tt.want*3 {
			t.Errorf("total for %s = %v, want %v", tt.itemID, resp.Total, tt.want*3)
		}
		if resp.ItemId != tt.itemID || resp.Quantity != 3 {
			t.Errorf("response echoed %s quantity %d, want %s quantity 3", resp.ItemId, resp.Quantity, tt.itemID)
		}
	}
}

// The default prices everything in USD; the scenario rule prices the west
// warehouse item in EUR and leaves the others alone.
func TestGetPriceCurrencyFollowsRegionalPricing(t *testing.T) {
	s := &pricingServer{}
	ctx := authedContext("test-token")

	t.Run("no rules", func(t *testing.T) {
		withServiceConfig(t, "test-token", "")
		for _, id := range []string{itemEast, itemWest} {
			resp, err := s.GetPrice(ctx, &ppb.PriceRequest{ItemId: id, Quantity: 1})
			if err != nil {
				t.Fatalf("GetPrice(%s): %v", id, err)
			}
			if resp.Currency != "USD" {
				t.Errorf("currency for %s = %s, want USD", id, resp.Currency)
			}
		}
	})

	t.Run("002=EUR", func(t *testing.T) {
		withServiceConfig(t, "test-token", "002=EUR")
		for _, tt := range []struct{ itemID, want string }{
			{itemEast, "USD"},
			{itemWest, "EUR"},
		} {
			resp, err := s.GetPrice(ctx, &ppb.PriceRequest{ItemId: tt.itemID, Quantity: 1})
			if err != nil {
				t.Fatalf("GetPrice(%s): %v", tt.itemID, err)
			}
			if resp.Currency != tt.want {
				t.Errorf("currency for %s = %s, want %s", tt.itemID, resp.Currency, tt.want)
			}
			// The rule changes the currency and nothing else.
			if resp.UnitPrice <= 0 {
				t.Errorf("unit price for %s = %v, want a price", tt.itemID, resp.UnitPrice)
			}
		}
	})
}

func TestEcho(t *testing.T) {
	withServiceConfig(t, "test-token", "")
	s := &echoServer{}

	_, err := s.Echo(context.Background(), &pb.EchoRequest{Message: "hello"})
	wantCode(t, err, codes.Unauthenticated)

	_, err = s.Echo(authedContext("test-token"), &pb.EchoRequest{Message: ""})
	wantCode(t, err, codes.InvalidArgument)

	resp, err := s.Echo(authedContext("test-token"), &pb.EchoRequest{Message: "hello"})
	if err != nil {
		t.Fatalf("Echo: %v", err)
	}
	if resp.Message != "hello" {
		t.Errorf("message = %q, want %q", resp.Message, "hello")
	}
}

// Health takes no token: it is what a liveness probe and the scenario checks
// call, neither of which carries one.
func TestHealthNeedsNoToken(t *testing.T) {
	withServiceConfig(t, "test-token", "")
	s := &echoServer{}

	resp, err := s.Health(context.Background(), &pb.HealthRequest{})
	if err != nil {
		t.Fatalf("Health: %v", err)
	}
	if resp.Status != "SERVING" {
		t.Errorf("status = %q, want SERVING", resp.Status)
	}
}
