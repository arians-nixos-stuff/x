// Command executor is a remote execution server for the REv2 protocol
// (third-party/remote-apis).
package main

import (
	"flag"
	"log"
	"net"

	repb "github.com/bazelbuild/remote-apis/build/bazel/remote/execution/v2"
	"google.golang.org/grpc"

	"executor/capabilities"
)

func main() {
	listen := flag.String("listen", "localhost:8980", "address to serve gRPC on")
	flag.Parse()

	log.Print("hello")

	lis, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatal(err)
	}
	srv := grpc.NewServer()
	repb.RegisterCapabilitiesServer(srv, &capabilities.Server{})
	log.Printf("serving on %s", lis.Addr())
	log.Fatal(srv.Serve(lis))
}
