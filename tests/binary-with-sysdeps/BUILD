load(
    "@io_tweag_rules_haskell//haskell:haskell.bzl",
    "haskell_test",
)

package(default_testonly = 1)

haskell_test(
    name = "binary-with-sysdeps",
    srcs = ["Main.hs"],
    tags = ["requires_zlib"],
    visibility = ["//visibility:public"],
    deps = [
        "//tests/hackage:base",
        "@zlib",
    ],
)
