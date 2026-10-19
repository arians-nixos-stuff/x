def _run_binary_impl(ctx: AnalysisContext) -> list[Provider]:
    out = ctx.actions.declare_output(ctx.attrs.out)
    ctx.actions.run(
        cmd_args(ctx.attrs.binary[RunInfo], out.as_output()),
        category = "run",
    )
    return [DefaultInfo(default_output = out)]

# Runs a binary as a build action, passing it the path of the file it must
# write. The binary has to bring everything it needs: under remote execution,
# actions run in an empty sandbox.
run_binary = rule(
    impl = _run_binary_impl,
    attrs = {
        "binary": attrs.dep(providers = [RunInfo]),
        "out": attrs.string(),
    },
)
