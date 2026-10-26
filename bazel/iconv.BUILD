load("@rules_foreign_cc//foreign_cc:defs.bzl", "configure_make")

package(default_visibility = ["//visibility:public"])

filegroup(
    name = "all_srcs",
    srcs = glob(["**"]),
    visibility = ["//visibility:public"],
)

configure_make(
    name = "iconv",
    configure_in_place = True,
    configure_options = [
        "--enable-static",
        "--enable-shared=no",
    ],
    # GCC 15 defaults to gnu23; libiconv 1.17's loop_wchar.h uses K&R-style
    # declarations that are incompatible with C23. Compile as gnu17.
    env = select({
        # https://github.com/bazelbuild/rules_foreign_cc/issues/947#issuecomment-1208960469
        "@platforms//os:macos": {
            "AR": "",
            "CFLAGS": "-std=gnu17",
        },
        "//conditions:default": {
            "CFLAGS": "-std=gnu17",
        },
    }),
    lib_source = ":all_srcs",
    out_static_libs = ["libiconv.a"],
)
