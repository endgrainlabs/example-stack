package main

import (
	"context"
	"testing"

	"github.com/grpc-ecosystem/go-grpc-middleware/v2/interceptors/recovery"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestPanicInAHandlerBecomesAnInternalError(t *testing.T) {
	interceptor := recovery.UnaryServerInterceptor(recovery.WithRecoveryHandler(recoverPanic))
	panicking := func(ctx context.Context, req any) (any, error) {
		panic("nil map write, or some such")
	}

	resp, err := interceptor(context.Background(), nil, &grpc.UnaryServerInfo{FullMethod: "/test/Panic"}, panicking)

	if resp != nil {
		t.Errorf("response = %v, want nil", resp)
	}
	wantCode(t, err, codes.Internal)
	if msg := status.Convert(err).Message(); msg != "internal error" {
		t.Errorf("message = %q, want the generic one; the panic text is for the log, not the client", msg)
	}
}
