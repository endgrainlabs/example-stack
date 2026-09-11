package main

import (
	"testing"

	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/descriptorpb"

	pb "github.com/endgrainlabs/example-stack/go-grpc/proto/echopb"
	ppb "github.com/endgrainlabs/example-stack/go-grpc/proto/pricingpb"
)

// The rawDesc blobs in generated .pb.go files are length-prefixed binary;
// editing an embedded string in place, instead of regenerating with protoc,
// corrupts them in ways that can still parse. Assert the descriptors carry
// what the .proto files declare.
func TestGeneratedDescriptorsIntact(t *testing.T) {
	cases := []struct {
		file      protoreflect.FileDescriptor
		goPackage string
	}{
		{
			(&pb.EchoRequest{}).ProtoReflect().Descriptor().ParentFile(),
			"github.com/endgrainlabs/example-stack/go-grpc/proto/echopb",
		},
		{
			(&ppb.PriceRequest{}).ProtoReflect().Descriptor().ParentFile(),
			"github.com/endgrainlabs/example-stack/go-grpc/proto/pricingpb",
		},
	}
	for _, c := range cases {
		if got := c.file.Syntax(); got != protoreflect.Proto3 {
			t.Errorf("%s: syntax = %v, want proto3", c.file.Path(), got)
		}
		opts, ok := c.file.Options().(*descriptorpb.FileOptions)
		if !ok {
			t.Errorf("%s: file options are %T, want *descriptorpb.FileOptions", c.file.Path(), c.file.Options())
			continue
		}
		if got := opts.GetGoPackage(); got != c.goPackage {
			t.Errorf("%s: go_package = %q, want %q", c.file.Path(), got, c.goPackage)
		}
	}
}
