# Execution platforms

Builds run locally by default. To run them on
[actiond](https://github.com/hermeticbuild/actiond) instead, start actiond and
point buck2 at it from `.buckconfig.local`, which is per checkout and not
committed.

## Start actiond

Download `linux-actiond_linux_<arch>` from an actiond release and run:

```
linux-actiond_linux_arm64 serve-vm \
  --listen=127.0.0.1:8980 \
  --memory-mib=8192 \
  --root=$HOME/.cache/actiond
```

`--memory-mib` defaults to 512, which is not enough to build the LLVM runtimes.
If actiond panics, its root may not boot again; start it with an empty one.

## Use it

Put this in `.buckconfig.local` at the repository root:

```ini
[build]
execution_platforms = x//platforms:actiond

[buck2_re_client]
engine_address = grpc://127.0.0.1:8980
action_cache_address = grpc://127.0.0.1:8980
cas_address = grpc://127.0.0.1:8980
tls = false
# actiond's maximum batch size; larger blobs go through ByteStream.
max_total_batch_size = 4194304
# actiond runs every action it is sent at once, in one small VM.
execution_concurrency_limit = 32
```

Run `buck2 kill` after changing it: the remote execution client is only set up
when the daemon starts.

Every action then runs in an empty sandbox, so only targets built with a
hermetic toolchain work there, such as `//toolchains/llvm/tests:hello-runs`.
