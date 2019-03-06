"""GHCi support"""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@io_tweag_rules_haskell//haskell:private/context.bzl", "haskell_context")
load(
    "@io_tweag_rules_haskell//haskell:private/path_utils.bzl",
    "ln",
    "target_unique_name",
)
load(
    "@io_tweag_rules_haskell//haskell:private/providers.bzl",
    "HaskellBinaryInfo",
    "HaskellBuildInfo",
    "HaskellLibraryInfo",
)
load("@io_tweag_rules_haskell//haskell:private/set.bzl", "set")


HaskellReplLoadInfo = provider(
    doc = """Haskell REPL target information.

    Information to a Haskell target to load into the REPL as source.
    """,
    fields = {
        # XXX: Do we need to distinguish boot and source files?
        # "boot_files": "Set of boot files",
        "source_files": "Set of files that contain Haskell modules.",
        # XXX: C libraries to load
    },
)

HaskellReplDepInfo = provider(
    doc = """Haskell REPL dependency information.

    Information to a Haskell target to load into the REPL as a built package.
    """,
    fields = {
        "package_id": "Workspace unique package identifier.",
        #"package_confs": "Set of package .conf files.",
        "package_caches": "Set of package cache files.",
    },
)

HaskellReplCollectInfo = provider(
    doc = """Collect Haskell REPL information.

    Holds information to generate a REPL that loads some targets as source
    and some targets as built packages.
    """,
    fields = {
        "load_infos": "Dictionary from labels to HaskellReplLoadInfo.",
        "dep_infos": "Dictionary from labels to HaskellReplDepInfo.",
        # XXX: Transitive C library dependencies.
        # XXX: Transitive prebuilt dependencies.
    },
)

HaskellReplInfo = provider(
    doc = """Haskell REPL information.

    Holds information to generate a REPL that loads a specific set of targets
    from source or as built packages.
    """,
    fields = {
        "source_files": "Set Haskell source files to load.",
        "package_ids": "Set of package ids to load.",
        #"package_confs": "Set of package .conf files.",
        "package_caches": "Set of package cache files.",
        # XXX: Transitive C library dependencies.
        # XXX: Transitive prebuilt dependencies.
    },
)


def _create_HaskellReplCollectInfo(target):
    collect_info = HaskellReplCollectInfo(
        load_infos = {},
        dep_infos = {},
    )

    if HaskellLibraryInfo in target:
        lib_info = target[HaskellLibraryInfo]
        build_info = target[HaskellBuildInfo]
        collect_info.load_infos[target.label] = HaskellReplLoadInfo(
            source_files = set.union(
                lib_info.boot_files,
                lib_info.source_files,
            ),
        )
        collect_info.dep_infos[target.label] = HaskellReplDepInfo(
            package_id = lib_info.package_id,
            #package_confs = build_info.package_confs,
            package_caches = build_info.package_caches,
        )
    elif HaskellBinaryInfo in target:
        bin_info = target[HaskellBinaryInfo]
        collect_info.load_infos[target.label] = HaskellReplLoadInfo(
            source_files = bin_info.source_files,
        )

    return collect_info


def _merge_HaskellReplCollectInfo(*args):
    info = HaskellReplCollectInfo(
        load_infos = {},
        dep_infos = {},
    )
    for arg in args:
        info.load_infos.update(arg.load_infos)
        info.dep_infos.update(arg.dep_infos)
    return info


def _create_HaskellReplInfo(load_labels, mask, collect_info):
    repl_info = HaskellReplInfo(
        source_files = set.empty(),
        package_ids = set.empty(),
        #package_confs = set.empty(),
        package_caches = set.empty(),
    )

    for (lbl, load_info) in collect_info.load_infos.items():
        if lbl not in load_labels:  # XXX: Check mask as well
            continue

        set.mutable_union(repl_info.source_files, load_info.source_files)

    for (lbl, dep_info) in collect_info.dep_infos.items():
        if lbl in load_labels:  # XXX: Check mask as well
            continue

        set.mutable_insert(repl_info.package_ids, dep_info.package_id)
        #set.mutable_union(repl_info.package_confs, dep_info.package_confs)
        set.mutable_union(repl_info.package_caches, dep_info.package_caches)

    return repl_info
            

def _create_repl(hs, ctx, repl_info):
    output = ctx.outputs.repl

    # The base and directory packages are necessary for the GHCi script we use
    # (loads source files and brings in scope the corresponding modules).
    args = ["-package", "base", "-package", "directory"]

    # Load prebuilt dependencies (-package)
    # XXX:
    # for package in set.to_list(repl_info.prebuilt_packages):
    #     args.extend(["-package", package])

    # Load built dependencies (-package-id, -package-db)
    for package_id in set.to_list(repl_info.package_ids):
        args.extend(["-package-id", package_id])
    for package_cache in set.to_list(repl_info.package_caches):
        args.extend(["-package-db", package_cache.dirname])

    # XXX: C library dependencies

    # Load source files
    add_sources = [
        "*" + f.path
        for f in set.to_list(repl_info.source_files)
    ]
    ghci_repl_script = hs.actions.declare_file(
        target_unique_name(hs, "ghci-repl-script"),
    )
    hs.actions.expand_template(
        template = ctx.file._ghci_repl_script,
        output = ghci_repl_script,
        substitutions = {
            "{ADD_SOURCES}": " ".join(add_sources),
        },
    )
    args += ["-ghci-script", ghci_repl_script.path]

    # Extra arguments.
    # `compiler flags` is the default set of arguments for the repl,
    # augmented by `repl_ghci_args`.
    # The ordering is important, first compiler flags (from toolchain
    # and local rule), then from `repl_ghci_args`. This way the more
    # specific arguments are listed last, and then have more priority in
    # GHC.
    # Note that most flags for GHCI do have their negative value, so a
    # negative flag in `repl_ghci_args` can disable a positive flag set
    # in `compiler_flags`, such as `-XNoOverloadedStrings` will disable
    # `-XOverloadedStrings`.
    args += (
        hs.toolchain.compiler_flags +
        # compiler_flags +
        hs.toolchain.repl_ghci_args
        # repl_ghci_args
    )

    ghci_repl_wrapper = hs.actions.declare_file(
        target_unique_name(hs, "ghci-repl-wrapper"),
    )
    hs.actions.expand_template(
        template = ctx.file._ghci_repl_wrapper,
        output = ghci_repl_wrapper,
        is_executable = True,
        substitutions = {
            "{LIBPATH}": "",  # ghc_env["LIBRARY_PATH"],
            "{LDLIBPATH}": "",  # ghc_env["LD_LIBRARY_PATH"],
            "{TOOL}": hs.tools.ghci.path,
            "{SCRIPT_LOCATION}": output.path,
            "{ARGS}": " ".join([shell.quote(a) for a in args]),
        },
    )

    # XXX We create a symlink here because we need to force
    # hs.tools.ghci and ghci_repl_script and the best way to do that is
    # to use hs.actions.run. That action, in turn must produce
    # a result, so using ln seems to be the only sane choice.
    extra_inputs = depset(transitive = [
        depset([
            hs.tools.ghci,
            ghci_repl_script,
            ghci_repl_wrapper,
        #    ghc_info_file,
        ]),
        set.to_depset(repl_info.package_caches),
        #depset(library_deps),
        #depset(ld_library_deps),
        #set.to_depset(source_files),
    ])
    ln(hs, ghci_repl_wrapper, output, extra_inputs)


def _haskell_repl_aspect_impl(target, ctx):
    is_eligible = (
        HaskellLibraryInfo in target or
        HaskellBinaryInfo in target
    )
    if not is_eligible:
        return []

    target_info = _create_HaskellReplCollectInfo(target)
    deps_infos = [
        dep[HaskellReplCollectInfo]
        for dep in ctx.rule.attr.deps
        if HaskellReplCollectInfo in dep
    ]
    collect_info = _merge_HaskellReplCollectInfo(*([target_info] + deps_infos))

    return [collect_info]

haskell_repl_aspect = aspect(
    implementation = _haskell_repl_aspect_impl,
    attr_aspects = ["deps"],
)


def _haskell_repl_impl(ctx):
    collect_info = _merge_HaskellReplCollectInfo(*[
        dep[HaskellReplCollectInfo]
        for dep in ctx.attr.deps
        if HaskellReplCollectInfo in dep
    ])
    load_labels = [dep.label for dep in ctx.attr.deps]
    repl_info = _create_HaskellReplInfo(load_labels, None, collect_info)
    hs = haskell_context(ctx)
    _create_repl(hs, ctx, repl_info)
    return [
        DefaultInfo()
    ]


haskell_repl = rule(
    implementation = _haskell_repl_impl,
    attrs = {
        "_ghci_repl_script": attr.label(
            allow_single_file = True,
            default = Label("@io_tweag_rules_haskell//haskell:assets/ghci_script"),
        ),
        "_ghci_repl_wrapper": attr.label(
            allow_single_file = True,
            default = Label("@io_tweag_rules_haskell//haskell:private/ghci_repl_wrapper.sh"),
        ),
        "deps": attr.label_list(
            aspects = [haskell_repl_aspect],
            doc = "List of Haskell targets to load into the REPL",
        ),
    },
    outputs = {
        "repl": "%{name}@repl",
    },
    toolchains = ["@io_tweag_rules_haskell//haskell:toolchain"],
)
