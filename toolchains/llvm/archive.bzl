"""Downloads and unpacks archives with a pinned, statically linked bsdtar.

Unlike the prelude's http_archive, nothing here runs a host tool, so these
actions work in an empty sandbox. Under remote execution, unpacking runs
remotely by default: the compressed archive is uploaded once and the extracted
files are created where the actions that use them run. Otherwise every remote
action using an extracted file would have to upload it first.
"""

ArchiveInfo = provider(fields = {
    # The extracted tree, with `strip_prefix` removed.
    "dir": Artifact,
    # mtree(5) listing of every entry in the archive, or None.
    "listing": Artifact | None,
    # The prefix removed from every path, if any, for reading `listing`.
    "strip_prefix": str | None,
})

def _hermetic_archive_impl(ctx: AnalysisContext) -> list[Provider]:
    archive = ctx.actions.declare_output("archive." + ctx.attrs.type)
    ctx.actions.download_file(archive.as_output(), ctx.attrs.url, sha256 = ctx.attrs.sha256, size_bytes = ctx.attrs.size_bytes)
    tar = ctx.attrs._tar[RunInfo]

    out = ctx.actions.declare_output(ctx.label.name, dir = True)
    prefix = ctx.attrs.strip_prefix + "/" if ctx.attrs.strip_prefix else ""

    # bsdtar cannot extract into a directory that does not exist yet, so
    # rewrite every path to start with the output directory instead of
    # changing into it. The S flag leaves symlink targets alone, since they are
    # relative to the link.
    rename = cmd_args(out.as_output(), format = ",^" + prefix + ",{}/,S")
    ctx.actions.run(
        cmd_args(tar, "-xf", archive, "-s", rename, ctx.attrs.include),
        category = "extract",
    )

    listing = None
    if ctx.attrs.listing:
        listing = ctx.actions.declare_output(ctx.label.name + ".mtree")
        ctx.actions.run(
            cmd_args(
                tar,
                "-cf",
                listing.as_output(),
                "--format=mtree",
                "--options=!all,type",
                cmd_args(archive, format = "@{}"),
            ),
            category = "list",
        )

    return [
        DefaultInfo(default_output = out),
        ArchiveInfo(dir = out, listing = listing, strip_prefix = ctx.attrs.strip_prefix),
    ]

hermetic_archive = rule(
    impl = _hermetic_archive_impl,
    attrs = {
        # Only extract entries matching these bsdtar patterns.
        "include": attrs.list(attrs.string(), default = []),
        # Also produce an mtree listing of the archive's entries.
        "listing": attrs.bool(default = False),
        "sha256": attrs.string(),
        # Known up front so a deferred download needs no HEAD request.
        "size_bytes": attrs.int(),
        "strip_prefix": attrs.option(attrs.string(), default = None),
        "type": attrs.enum(["tar.gz", "tar.zst"]),
        "url": attrs.string(),
        "_tar": attrs.exec_dep(providers = [RunInfo], default = "//toolchains/llvm:bsdtar"),
    },
)

def read_mtree_files(listing: str, strip_prefix: str | None) -> list[str]:
    """Regular files in an mtree listing, relative to the extracted tree."""
    prefix = "./" + strip_prefix + "/" if strip_prefix else "./"
    files = []
    for line in listing.splitlines():
        if not line.startswith(prefix) or not line.endswith(" type=file"):
            continue
        files.append(line[len(prefix):-len(" type=file")])
    return files

def _static_binary_impl(ctx: AnalysisContext) -> list[Provider]:
    out = ctx.actions.declare_output(ctx.label.name)
    ctx.actions.download_file(out.as_output(), ctx.attrs.url, sha256 = ctx.attrs.sha256, size_bytes = ctx.attrs.size_bytes, is_executable = True)
    return [DefaultInfo(default_output = out), RunInfo(args = cmd_args(out))]

static_binary = rule(
    impl = _static_binary_impl,
    attrs = {
        "sha256": attrs.string(),
        # Known up front so a deferred download needs no HEAD request.
        "size_bytes": attrs.int(),
        "url": attrs.string(),
    },
)
