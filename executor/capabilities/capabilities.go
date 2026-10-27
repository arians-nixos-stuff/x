// Package capabilities implements the REv2 Capabilities service, which tells
// clients what this server supports.
package capabilities

import (
	"context"

	repb "github.com/bazelbuild/remote-apis/build/bazel/remote/execution/v2"
	smpb "github.com/bazelbuild/remote-apis/build/bazel/semver"
)

type Server struct {
	repb.UnimplementedCapabilitiesServer
}

func (*Server) GetCapabilities(context.Context, *repb.GetCapabilitiesRequest) (*repb.ServerCapabilities, error) {
	return repb.ServerCapabilities_builder{
		CacheCapabilities: repb.CacheCapabilities_builder{
			DigestFunctions: []repb.DigestFunction_Value{repb.DigestFunction_SHA256},
			ActionCacheUpdateCapabilities: repb.ActionCacheUpdateCapabilities_builder{
				UpdateEnabled: false,
			}.Build(),
			SymlinkAbsolutePathStrategy: repb.SymlinkAbsolutePathStrategy_DISALLOWED,
		}.Build(),
		ExecutionCapabilities: repb.ExecutionCapabilities_builder{
			DigestFunction:  repb.DigestFunction_SHA256,
			DigestFunctions: []repb.DigestFunction_Value{repb.DigestFunction_SHA256},
			ExecEnabled:     false,
		}.Build(),
		LowApiVersion:  smpb.SemVer_builder{Major: 2}.Build(),
		HighApiVersion: smpb.SemVer_builder{Major: 2, Minor: 3}.Build(),
	}.Build(), nil
}
