"""GHCi support"""


HaskellReplInfo = provider(
    doc = "REPL-specific information.",
    fields = {
        "boot_files": "Set of boot files",
        "source_files": "Set of files that contain Haskell modules.",
    },
)


def _merge_HaskellReplInfo(*args):
    return HaskellReplInfo(
        boot_files = [arg.boot_files for arg in args],
        source_files = [arg.source_files for arg in args],
    )


def _haskell_repl_aspect_impl(target, ctx):
    if HaskellLibraryInfo in target:
        info = target[HaskellLibraryInfo]
        repl_info = HaskellReplInfo(
            boot_files = info.boot_files,
            source_files = info.source_files,
        )
    elif HaskellBinaryInfo in target:
        # XXX: Same as above
        pass
    return [repl_info]


haskell_repl_aspect = aspect(
    implementation = _haskell_repl_aspect_impl,
    attr_aspects = ["deps"],
    attrs = {
        "_ghci_repl_wrapper": attr.label(
            default = Label("@io_tweag_rules_haskell//haskell:private/ghci_repl_wrapper.sh"),
        ),
    },
    toolchains = ["@io_tweag_rules_haskell//haskell:toolchain"],
)


def _haskell_repl_impl(ctx):
    repl_info = _merge_HaskellReplInfo([
        dep[HaskellReplInfo]
        for dep in ctx.attr.deps
        if HaskellReplInfo in dep
    ])
    print(repl_info)
    return [
        DefaultInfo()
    ]


haskell_repl = rule(
    implementation = _haskell_repl_impl,
    attrs = {
        "deps": attr.label_list(
            aspects = [haskell_repl_aspect],
            doc = "List of Haskell targets to load into the REPL",
        ),
    },
)
