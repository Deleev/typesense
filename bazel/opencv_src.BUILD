# opencv 4.5.4 sources vendored for the onnxruntime-extensions CMake build.
# onnxruntime-extensions' cmake/externals/opencv.cmake FetchContent-declares
# opencv with GIT_REPOSITORY, which clones GitHub at CMake configure time.
# bazel/onnxruntime.BUILD sets FETCHCONTENT_SOURCE_DIR_OPENCV to this
# repository ($EXT_BUILD_ROOT/external/opencv_src) so no clone happens.
# This target exists only to make Bazel fetch and materialize the external
# repository; the cmake() target depends on it via `data`.
filegroup(
    name = "all_srcs",
    srcs = glob(["**"]),
    visibility = ["//visibility:public"],
)
