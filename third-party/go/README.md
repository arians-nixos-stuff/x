# Third-party Go packages

Go packages are vendored in `vendor/` and built from BUCK files that
[gobuckify](../buck2/prelude/go/tools/gobuckify) generates there, one
`go_library` (or `go_binary`, for a command) per package, at
`//third-party/go/vendor/<import path>:<last path element>`.

`go.mod` pins the versions. It belongs to a placeholder module whose only
source, `deps.go`, imports every third-party package that code in this
repository imports directly; that is what `go mod tidy` and `go mod vendor` go
by. Commands that the build runs, such as the protoc plugins, are `tool`
dependencies in `go.mod` instead (`go get -tool <package>`). Code here is built
by Buck and has no `go.mod` of its own.

Projects vendored with josh, such as `third-party/remote-apis`, are not Go
modules here: their BUCK files are written by hand, next to their sources, and
depend on packages vendored here. List their imports in `deps.go` too, at
versions no older than their own `go.mod` asks for.

## Updating

After changing `deps.go` or `go.mod`:

```sh
nix develop --command bash -c '
  cd third-party/go && go mod tidy && go mod vendor && cd ../.. &&
  buck2 run prelude//go/tools/gobuckify:gobuckify -- third-party/go'
```

`go mod vendor` replaces `vendor/`, BUCK files included, so always run
gobuckify after it. If jj's `snapshot.auto-track` is off, follow up with
`jj file track third-party/go`: a snapshot taken while `vendor/` was being
replaced records its files as deleted, and they come back untracked. CI fails
when `third-party/go` is not up to date with these commands.
