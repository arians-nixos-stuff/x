package capabilities

import (
	"context"
	"net"
	"testing"

	repb "github.com/bazelbuild/remote-apis/build/bazel/remote/execution/v2"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func TestGetCapabilities(t *testing.T) {
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := grpc.NewServer()
	repb.RegisterCapabilitiesServer(srv, &Server{})
	go srv.Serve(lis)
	t.Cleanup(srv.Stop)

	conn, err := grpc.NewClient(lis.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })

	caps, err := repb.NewCapabilitiesClient(conn).GetCapabilities(context.Background(), &repb.GetCapabilitiesRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if got := caps.GetCacheCapabilities().GetDigestFunctions(); len(got) != 1 || got[0] != repb.DigestFunction_SHA256 {
		t.Errorf("cache digest functions = %v, want [SHA256]", got)
	}
	if caps.GetExecutionCapabilities().GetExecEnabled() {
		t.Error("execution is enabled, but not implemented")
	}
}
