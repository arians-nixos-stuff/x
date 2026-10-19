"""A hermetic LLVM C toolchain, ported from hermeticbuild/hermetic-llvm.

The compiler is hermetic-llvm's prebuilt, statically linked LLVM ("stage 0").
Everything a target needs is built from source with it: musl's libc and start
files, compiler-rt's builtins and crtbegin/crtend. No host tools, sysroot or
shell are involved, so every action also runs in an empty sandbox.
"""

load(
    "@prelude//cxx:cxx_toolchain_types.bzl",
    "BinaryUtilitiesInfo",
    "CCompilerInfo",
    "CxxCompilerInfo",
    "CxxInternalTools",
    "CxxPlatformInfo",
    "CxxToolchainInfo",
    "DepTrackingMode",
    "LinkerInfo",
    "LinkerType",
    "PicBehavior",
    "RuntimeDependencyHandling",
    "ShlibInterfacesMode",
)
load("@prelude//cxx:headers.bzl", "HeaderMode")
load("@prelude//linking:link_info.bzl", "LinkStyle")
load("@prelude//linking:lto.bzl", "LtoMode")
load(":archive.bzl", "ArchiveInfo", "read_mtree_files")
load(":compiler_rt_srcs.bzl", "BUILTINS_BF16_SRCS", "BUILTINS_GENERIC_SRCS", "BUILTINS_TF_SRCS")

LlvmInfo = provider(fields = {
    "clang": RunInfo,
    "llvm_ar": RunInfo,
    "resource_dir": Artifact,
})

TargetRuntimesInfo = provider(fields = {
    "triple": str,
    # Directory with crt1.o, crti.o, crtbegin.o and friends, for -B.
    "crt_dir": Artifact,
    # Directory with libc.a and empty stand-ins for musl's other libraries, for -L.
    "lib_dir": Artifact,
    # The C library's headers, for -isystem.
    "include_dir": Artifact,
    # clang's resource directory plus libclang_rt.builtins.a, for linking.
    "resource_dir": Artifact,
})

def _llvm_tool(dist: Artifact, name: str) -> RunInfo:
    # bin/ holds one multicall `llvm` binary and a symlink per tool name; the
    # whole tree is an input so the symlink resolves and clang finds its
    # resource directory next to it.
    return RunInfo(args = cmd_args(dist.project("bin/" + name), hidden = dist))

def _llvm_dist_impl(ctx: AnalysisContext) -> list[Provider]:
    dist = ctx.attrs.archive[ArchiveInfo].dir
    return [
        DefaultInfo(default_output = dist),
        LlvmInfo(
            clang = _llvm_tool(dist, "clang"),
            llvm_ar = _llvm_tool(dist, "llvm-ar"),
            resource_dir = dist.project("lib/clang/" + ctx.attrs.version_major),
        ),
    ]

llvm_dist = rule(
    impl = _llvm_dist_impl,
    attrs = {
        "archive": attrs.dep(providers = [ArchiveInfo]),
        "version_major": attrs.string(),
    },
)

# Flags every runtime compile starts with. Runtimes are built freestanding:
# nothing from the host, and no libc until musl provides one.
def _runtime_compile_flags(triple: str) -> list[str]:
    return [
        "--target=" + triple,
        "-no-canonical-prefixes",
        "--sysroot=/dev/null",
        "-Wno-builtin-macro-redefined",
        "-D__DATE__=\"redacted\"",
        "-D__TIMESTAMP__=\"redacted\"",
        "-D__TIME__=\"redacted\"",
        "-ffile-compilation-dir=.",
        "-O2",
        "-DNDEBUG",
    ]

def _compile(ctx: AnalysisContext, llvm: LlvmInfo, src: Artifact | cmd_args, out: Artifact, flags, identifier: str, category: str):
    ctx.actions.run(
        cmd_args(llvm.clang, flags, "-c", src, "-o", out.as_output()),
        category = category,
        identifier = identifier,
    )

def _archive(ctx: AnalysisContext, llvm: LlvmInfo, out: Artifact, objects: list[Artifact], name: str):
    members = ctx.actions.write(name + ".members", cmd_args(objects))
    ctx.actions.run(
        cmd_args(llvm.llvm_ar, "rcsD", out.as_output(), cmd_args(members, format = "@{}"), hidden = objects),
        category = "archive",
        identifier = name,
    )

def _empty_archive(ctx: AnalysisContext, llvm: LlvmInfo, name: str) -> Artifact:
    out = ctx.actions.declare_output("lib/" + name)
    ctx.actions.run(
        cmd_args(llvm.llvm_ar, "rcD", out.as_output(), "--format=gnu"),
        category = "archive",
        identifier = name,
    )
    return out

_MUSL_ARCHES = [
    "aarch64",
    "arm",
    "generic",
    "i386",
    "loongarch64",
    "m68k",
    "microblaze",
    "mips",
    "mips64",
    "mipsn32",
    "or1k",
    "powerpc",
    "powerpc64",
    "riscv32",
    "riscv64",
    "s390x",
    "sh",
    "x32",
    "x86_64",
]

def _split_path(path: str) -> (str, str):
    parts = path.rsplit("/", 1)
    return (parts[0], parts[1]) if len(parts) == 2 else ("", path)

def _stem(name: str) -> str:
    return name.rsplit(".", 1)[0]

def musl_sources(files: list[str], arch: str) -> list[str]:
    """musl's ARCH_SRCS replacing BASE_SRCS, as in its Makefile."""
    srcs = [f for f in files if f.startswith("src/") and f.rsplit(".", 1)[-1] in ("c", "s", "S") and not f.startswith("src/malloc/oldmalloc/")]
    replaced = {}
    for f in srcs:
        directory, name = _split_path(f)
        parent, leaf = _split_path(directory)
        if leaf == arch:
            replaced[parent + "/" + _stem(name)] = True
    selected = []
    for f in srcs:
        directory, name = _split_path(f)
        if _split_path(directory)[1] in _MUSL_ARCHES:
            if _split_path(directory)[1] == arch:
                selected.append(f)
        elif directory + "/" + _stem(name) not in replaced:
            selected.append(f)
    return selected

def musl_alltypes(text: str) -> str:
    """tools/mkalltypes.sed."""
    out = []
    for line in text.splitlines():
        for kind in ("TYPEDEF", "STRUCT", "UNION"):
            if line.startswith(kind) and line.endswith(";"):
                body = line[len(kind):-1]
                if kind == "TYPEDEF":
                    if not body.startswith(" ") or " " not in body[1:]:
                        break
                    typ, name = body[1:].rsplit(" ", 1)
                    need = name
                    decl = "typedef {} {};".format(typ, name)
                else:
                    rest = body.lstrip(" ")
                    if " " not in rest:
                        break
                    name, members = rest.split(" ", 1)
                    need = kind.lower() + "_" + name
                    decl = "{} {} {};".format(kind.lower(), name, members)
                line = "#if defined(__NEED_{0}) && !defined(__DEFINED_{0})\n{1}\n#define __DEFINED_{0}\n#endif\n".format(need, decl)
                break
        out.append(line)
    return "\n".join(out) + "\n"

def musl_syscall(text: str) -> str:
    """cp syscall.h.in && sed -n -e s/__NR_/SYS_/p."""
    aliases = [line.replace("__NR_", "SYS_", 1) for line in text.splitlines() if "__NR_" in line]
    return text + "\n".join(aliases) + "\n"

_MUSL_FLAGS = [
    # CFLAGS_C99FSE
    "-std=c99",
    "-nostdinc",
    "-ffreestanding",
    "-fexcess-precision=standard",
    "-frounding-math",
    "-fno-strict-aliasing",
    "-Wa,--noexecstack",
    "-D_XOPEN_SOURCE=700",
    # CFLAGS_AUTO
    "-fno-align-functions",
    "-fomit-frame-pointer",
    "-fno-unwind-tables",
    "-fno-asynchronous-unwind-tables",
    "-w",
    "-Qunused-arguments",
]

_CRT_FLAGS = ["-DCRT", "-fno-stack-protector", "-fno-addrsig"]

def _musl(ctx: AnalysisContext, llvm: LlvmInfo, triple: str, arch: str) -> (Artifact, Artifact, dict[str, Artifact]):
    musl = ctx.attrs.musl[ArchiveInfo]
    src = musl.dir
    libc = ctx.actions.declare_output("lib/libc.a")
    include_dir = ctx.actions.declare_output("musl/include", dir = True)
    crt = {name: ctx.actions.declare_output("crt/" + name) for name in ("crt1.o", "rcrt1.o", "Scrt1.o")}
    inputs = {
        "alltypes_arch": src.project("arch/{}/bits/alltypes.h.in".format(arch)),
        "alltypes": src.project("include/alltypes.h.in"),
        "syscall": src.project("arch/{}/bits/syscall.h.in".format(arch)),
        "version": src.project("VERSION"),
    }

    def generate_and_build(ctx: AnalysisContext, artifacts, outputs):
        files = read_mtree_files(artifacts[musl.listing].read_string(), musl.strip_prefix)
        alltypes = ctx.actions.write(
            "musl/gen/alltypes.h",
            musl_alltypes(artifacts[inputs["alltypes_arch"]].read_string()) + musl_alltypes(artifacts[inputs["alltypes"]].read_string()),
        )
        syscall = ctx.actions.write("musl/gen/syscall.h", musl_syscall(artifacts[inputs["syscall"]].read_string()))
        version = ctx.actions.write(
            "musl/gen/version.h",
            "#define VERSION \"{}\"\n".format(artifacts[inputs["version"]].read_string().strip()),
        )
        obj_include = ctx.actions.copied_dir("musl/gen/include", {"bits/alltypes.h": alltypes, "bits/syscall.h": syscall})
        obj_internal = ctx.actions.copied_dir("musl/gen/internal", {"version.h": version})

        flags = cmd_args(
            _runtime_compile_flags(triple),
            _MUSL_FLAGS,
            cmd_args(src, format = "-I{}/arch/" + arch),
            cmd_args(src, format = "-I{}/arch/generic"),
            cmd_args(obj_internal, format = "-I{}"),
            cmd_args(src, format = "-I{}/src/include"),
            cmd_args(src, format = "-I{}/src/internal"),
            cmd_args(obj_include, format = "-I{}"),
            cmd_args(src, format = "-I{}/include"),
            # arch sources include their generic counterparts by relative path.
            hidden = src,
        )

        objects = []
        for f in musl_sources(files, arch):
            obj = ctx.actions.declare_output("musl/obj/" + f + ".o")
            _compile(ctx, llvm, src.project(f), obj, flags, f, "musl_compile")
            objects.append(obj)
        _archive(ctx, llvm, outputs[libc], objects, "libc.a")

        for name, extra in (("crt1.o", []), ("rcrt1.o", ["-fPIC"]), ("Scrt1.o", ["-fPIC"])):
            _compile(ctx, llvm, src.project("crt/" + _stem(name) + ".c"), outputs[crt[name]], cmd_args(flags, _CRT_FLAGS, extra), name, "musl_compile")

        # Public headers: generic bits first, so the arch's own bits replace them.
        headers = {}
        for f in files:
            directory, name = _split_path(f)
            if not name.endswith(".h"):
                continue
            if f.startswith("include/"):
                headers[f[len("include/"):]] = src.project(f)
            elif directory == "arch/generic/bits":
                headers.setdefault("bits/" + name, src.project(f))
        for f in files:
            if f.startswith("arch/{}/bits/".format(arch)) and f.endswith(".h"):
                headers["bits/" + _split_path(f)[1]] = src.project(f)
        headers["bits/alltypes.h"] = alltypes
        headers["bits/syscall.h"] = syscall
        ctx.actions.copied_dir(outputs[include_dir], headers)

    ctx.actions.dynamic_output(
        dynamic = [musl.listing] + inputs.values(),
        inputs = [],
        outputs = [libc.as_output(), include_dir.as_output()] + [o.as_output() for o in crt.values()],
        f = generate_and_build,
    )
    return libc, include_dir, crt

_LSE_PATTERNS = ["cas", "swp", "ldadd", "ldclr", "ldeor", "ldset"]

def _compiler_rt(ctx: AnalysisContext, llvm: LlvmInfo, triple: str, musl_include: Artifact) -> (Artifact, dict[str, Artifact]):
    builtins = ctx.attrs.compiler_rt[ArchiveInfo].dir.project("compiler-rt/lib/builtins")
    base = cmd_args(
        _runtime_compile_flags(triple),
        "-nostdlibinc",
        cmd_args(llvm.resource_dir, format = "-resource-dir={}"),
        cmd_args(builtins, format = "-I{}"),
        hidden = builtins,
    )
    flags = cmd_args(
        base,
        cmd_args(musl_include, format = "-isystem{}"),
        "-fno-builtin",
        "-std=c11",
        "-fvisibility=hidden",
        "-fomit-frame-pointer",
        "-mbranch-protection=standard",
        "-DCOMPILER_RT_HAS_FLOAT16",
    )

    srcs = [s for s in BUILTINS_GENERIC_SRCS if s != "fp_mode.c"] + BUILTINS_BF16_SRCS + BUILTINS_TF_SRCS + [
        "aarch64/fp_mode.c",
        "cpu_model/aarch64.c",
    ]
    objects = []
    for s in srcs:
        obj = ctx.actions.declare_output("compiler-rt/obj/" + s + ".o")
        _compile(ctx, llvm, builtins.project(s), obj, flags, s, "compiler_rt_compile")
        objects.append(obj)

    # Outline atomics: lse.S once per operation, size and memory model.
    lse = builtins.project("aarch64/lse.S")
    for pat in _LSE_PATTERNS:
        for size in [1, 2, 4, 8, 16]:
            if size == 16 and pat != "cas":
                continue
            for model in [1, 2, 3, 4, 5]:
                name = "lse_{}_{}_{}".format(pat, size, model)
                obj = ctx.actions.declare_output("compiler-rt/obj/aarch64/{}.o".format(name))
                lse_flags = cmd_args(
                    base,
                    "-nobuiltininc",
                    "-mbranch-protection=standard",
                    "-DL_" + pat,
                    "-DSIZE={}".format(size),
                    "-DMODEL={}".format(model),
                )
                _compile(ctx, llvm, lse, obj, lse_flags, name, "compiler_rt_compile")
                objects.append(obj)

    builtins_a = ctx.actions.declare_output("compiler-rt/libclang_rt.builtins.a")
    _archive(ctx, llvm, builtins_a, objects, "libclang_rt.builtins.a")

    crt_flags = cmd_args(
        base,
        "-std=c11",
        "-fPIC",
        "-fno-addrsig",
        "-mbranch-protection=standard",
        "-DCRT_HAS_INITFINI_ARRAY",
        "-DCRT_USE_FRAME_REGISTRY",
    )
    crt = {}
    for name in ("crtbegin", "crtend"):
        obj = ctx.actions.declare_output("crt/{}.o".format(name))
        _compile(ctx, llvm, builtins.project(name + ".c"), obj, crt_flags, name, "compiler_rt_compile")
        crt[name + ".o"] = obj

    # clang's Linux driver always asks for crti.o and crtn.o; musl needs no
    # _init/_fini content, so they are empty.
    empty = ctx.actions.write("crt/empty.c", "")
    for name in ("crti.o", "crtn.o"):
        obj = ctx.actions.declare_output("crt/" + name)
        _compile(ctx, llvm, empty, obj, cmd_args(_runtime_compile_flags(triple), "-fno-addrsig"), name, "compiler_rt_compile")
        crt[name] = obj
    return builtins_a, crt

def _target_runtimes_impl(ctx: AnalysisContext) -> list[Provider]:
    llvm = ctx.attrs.llvm[LlvmInfo]
    triple = ctx.attrs.triple
    arch = triple.split("-", 1)[0]

    libc, include_dir, musl_crt = _musl(ctx, llvm, triple, arch)
    builtins_a, rt_crt = _compiler_rt(ctx, llvm, triple, include_dir)

    crt_files = dict(musl_crt)
    crt_files.update(rt_crt)
    crt_files["crtbeginS.o"] = rt_crt["crtbegin.o"]
    crt_files["crtbeginT.o"] = rt_crt["crtbegin.o"]
    crt_files["crtendS.o"] = rt_crt["crtend.o"]
    crt_dir = ctx.actions.copied_dir("crt_dir", crt_files)

    libs = {"libc.a": libc}
    for name in ("libm.a", "librt.a", "libpthread.a", "libutil.a", "libresolv.a", "libdl.a", "libcrypt.a", "libxnet.a"):
        libs[name] = _empty_archive(ctx, llvm, name)
    lib_dir = ctx.actions.copied_dir("lib_dir", libs)

    resource_dir = ctx.actions.copied_dir("resource_dir", {
        "include": llvm.resource_dir.project("include"),
        "lib/{}/libclang_rt.builtins.a".format(_runtime_triple(triple)): builtins_a,
    })

    return [
        DefaultInfo(default_outputs = [crt_dir, lib_dir, include_dir, resource_dir]),
        TargetRuntimesInfo(
            triple = triple,
            crt_dir = crt_dir,
            lib_dir = lib_dir,
            include_dir = include_dir,
            resource_dir = resource_dir,
        ),
    ]

def _runtime_triple(triple: str) -> str:
    # clang's per-target runtime directory uses the normalized triple.
    arch, rest = triple.split("-", 1)
    return arch + "-unknown-" + rest

target_runtimes = rule(
    impl = _target_runtimes_impl,
    attrs = {
        "compiler_rt": attrs.dep(providers = [ArchiveInfo]),
        "llvm": attrs.dep(providers = [LlvmInfo]),
        "musl": attrs.dep(providers = [ArchiveInfo]),
        "triple": attrs.string(),
    },
)

def _llvm_cxx_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    llvm = ctx.attrs.llvm[LlvmInfo]
    rt = ctx.attrs.runtimes[TargetRuntimesInfo]

    compile_flags = cmd_args(
        "--target=" + rt.triple,
        "-no-canonical-prefixes",
        "--sysroot=/dev/null",
        "-nostdlibinc",
        cmd_args(rt.include_dir, format = "-isystem{}"),
        cmd_args(llvm.resource_dir, format = "-resource-dir={}"),
        "-Wno-builtin-macro-redefined",
        "-D__DATE__=\"redacted\"",
        "-D__TIMESTAMP__=\"redacted\"",
        "-D__TIME__=\"redacted\"",
        "-ffile-compilation-dir=.",
    )
    link_flags = cmd_args(
        "--target=" + rt.triple,
        "--sysroot=/dev/null",
        "-static",
        "-fuse-ld=lld",
        "-rtlib=compiler-rt",
        "--unwindlib=none",
        "-nostdlib++",
        "-Wl,-z,relro,-z,now",
        cmd_args(rt.crt_dir, format = "-B{}"),
        cmd_args(rt.lib_dir, format = "-L{}"),
        cmd_args(rt.resource_dir, format = "-resource-dir={}"),
    )
    compiler = CCompilerInfo(
        compiler = llvm.clang,
        compiler_type = "clang",
        compiler_flags = compile_flags,
        preprocessor_flags = [],
    )
    return [
        DefaultInfo(),
        CxxToolchainInfo(
            internal_tools = ctx.attrs._internal_tools[CxxInternalTools],
            linker_info = LinkerInfo(
                linker = llvm.clang,
                linker_flags = link_flags,
                post_linker_flags = [],
                archiver = llvm.llvm_ar,
                archiver_type = "gnu",
                archiver_supports_argfiles = True,
                generate_linker_maps = False,
                lto_mode = LtoMode("none"),
                type = LinkerType("gnu"),
                link_binaries_locally = False,
                link_libraries_locally = False,
                archive_objects_locally = False,
                use_archiver_flags = True,
                static_dep_runtime_ld_flags = [],
                static_pic_dep_runtime_ld_flags = [],
                shared_dep_runtime_ld_flags = [],
                independent_shlib_interface_linker_flags = [],
                shlib_interfaces = ShlibInterfacesMode("disabled"),
                link_style = LinkStyle("static"),
                link_weight = 1,
                binary_extension = "",
                object_file_extension = "o",
                shared_library_name_default_prefix = "lib",
                shared_library_name_format = "{}.so",
                shared_library_versioned_name_format = "{}.so.{}",
                static_library_extension = "a",
                force_full_hybrid_if_capable = False,
                is_pdb_generated = False,
            ),
            bolt_enabled = False,
            binary_utilities_info = BinaryUtilitiesInfo(
                nm = llvm.clang,
                objcopy = llvm.clang,
                objdump = llvm.clang,
                ranlib = llvm.llvm_ar,
                strip = llvm.clang,
                dwp = None,
            ),
            c_compiler_info = compiler,
            cxx_compiler_info = CxxCompilerInfo(
                compiler = llvm.clang,
                compiler_type = "clang",
                compiler_flags = compile_flags,
                preprocessor_flags = [],
            ),
            as_compiler_info = compiler,
            asm_compiler_info = compiler,
            header_mode = HeaderMode("symlink_tree_only"),
            cpp_dep_tracking_mode = DepTrackingMode("none"),
            pic_behavior = PicBehavior("supported"),
            use_dep_files = False,
            runtime_dependency_handling = RuntimeDependencyHandling("no_symlink"),
        ),
        CxxPlatformInfo(name = rt.triple),
    ]

llvm_cxx_toolchain = rule(
    impl = _llvm_cxx_toolchain_impl,
    is_toolchain_rule = True,
    attrs = {
        "llvm": attrs.exec_dep(providers = [LlvmInfo]),
        "runtimes": attrs.dep(providers = [TargetRuntimesInfo]),
        "_internal_tools": attrs.default_only(attrs.exec_dep(providers = [CxxInternalTools], default = "prelude//cxx/tools:internal_tools")),
    },
)

def _llvm_smoke_test_impl(ctx: AnalysisContext) -> list[Provider]:
    llvm = ctx.attrs.llvm[LlvmInfo]
    src = ctx.actions.write("empty.c", "")
    out = ctx.actions.declare_output("empty.o")
    _compile(ctx, llvm, src, out, _runtime_compile_flags(ctx.attrs.triple), "empty.c", "llvm_smoke")
    return [DefaultInfo(default_output = out)]

# Compiles an empty file: the cheapest check that the prebuilt compiler runs
# where actions run. Under remote execution it also uploads the compiler once,
# before the many actions that need it ask for it at the same time.
llvm_smoke_test = rule(
    impl = _llvm_smoke_test_impl,
    attrs = {
        "llvm": attrs.exec_dep(providers = [LlvmInfo]),
        "triple": attrs.string(),
    },
)
