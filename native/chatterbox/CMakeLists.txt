# libchatterbox_ffi — the C boundary the Flutter app loads over dart:ffi.
#
# Builds codec.cpp (which vendors ggml 0.9) plus its ISOLATED llama.cpp
# backbone, and wraps both behind src/chatterbox_ffi.cpp.
#
# The two-ggml split is the awkward part and is not ours to fix: codec.cpp
# links ggml 0.9, the pinned llama.cpp bundles ggml 0.15, and both produce a
# libggml with the same soname. codec.cpp's own cmake/SetupTtsBackbone.cmake
# resolves it by building llama.cpp static and wrapping it in a single shared
# object that exports only `llama_*`/`common_*`, hiding every `ggml_*` symbol
# as local so the two instances never resolve against each other. We inherit
# that machinery rather than reproducing it.

cmake_minimum_required(VERSION 3.22)
project(chatterbox_ffi CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(CODEC_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/vendor/codec.cpp"
    CACHE PATH "codec.cpp checkout")

if(NOT EXISTS "${CODEC_CPP_DIR}/CMakeLists.txt")
    message(FATAL_ERROR
        "codec.cpp is not checked out at ${CODEC_CPP_DIR}.\n"
        "See native/chatterbox/README.md — it is a submodule and needs\n"
        "  git submodule update --init --recursive")
endif()

# Vulkan is off by default on measurement: offloading the decode loop to a
# discrete GPU ran ~30% SLOWER than eight CPU threads, because autoregressive
# decode dispatches one token at a time and never builds a batch wide enough to
# repay the round trip. Switchable because a phone's unified memory has no such
# transfer, and that case is untested.
option(CHATTERBOX_VULKAN "Build the decode backbone with Vulkan" OFF)

# Metal is the Apple equivalent, and the one case where GPU offload might yet
# pay: unified memory means there is no transfer to repay per dispatch, which
# is what made Vulkan a loss on a discrete GPU. Untested.
option(CHATTERBOX_METAL "Build the decode backbone with Metal (Apple)" OFF)

# Upstream defines the codec_tts_runner library — the reference host loop this
# shim wraps — inside its `if(CODEC_BUILD_TTS_CLI)` block, so the flag has to
# stay on even though the CLI binary itself is of no use to us.
# Vulkan-Hpp for the cross-compiled backbone.
#
# The NDK ships Vulkan's C headers but no C++ bindings, and ggml-vulkan.cpp
# needs <vulkan/vulkan.hpp>. The version is not free to choose: Vulkan-Hpp
# static-asserts that VK_HEADER_VERSION matches the C headers it sits on, and
# releases after ~1.3.275 dropped API this llama.cpp still uses — streaming a
# vk::Buffer to an ostream, for one. The host's copy is whatever the distro
# ships (341 on this machine) and does not work.
#
# Fetched rather than vendored: it is 19 MB of generated headers, which has no
# business in a Flutter app's history.
if(CHATTERBOX_VULKAN AND NOT VULKAN_HPP_DIR)
    set(_vkhpp_version "1.3.275")
    set(_vkhpp_root "${CMAKE_CURRENT_SOURCE_DIR}/third_party/vulkan-hpp")

    if(NOT EXISTS "${_vkhpp_root}/vulkan.hpp")
        set(_vkhpp_tar "${CMAKE_BINARY_DIR}/vulkan-hpp-${_vkhpp_version}.tar.gz")
        message(STATUS "Fetching Vulkan-Hpp ${_vkhpp_version}")
        file(DOWNLOAD
            "https://github.com/KhronosGroup/Vulkan-Hpp/archive/refs/tags/v${_vkhpp_version}.tar.gz"
            "${_vkhpp_tar}" STATUS _vkhpp_status TLS_VERIFY ON)
        list(GET _vkhpp_status 0 _vkhpp_rc)
        if(NOT _vkhpp_rc EQUAL 0)
            list(GET _vkhpp_status 1 _vkhpp_err)
            message(FATAL_ERROR
                "Could not fetch Vulkan-Hpp ${_vkhpp_version}: ${_vkhpp_err}\n"
                "Download it by hand and point -DVULKAN_HPP_DIR at its "
                "vulkan/ directory, or build with -DCHATTERBOX_VULKAN=OFF.")
        endif()
        file(ARCHIVE_EXTRACT INPUT "${_vkhpp_tar}"
             DESTINATION "${CMAKE_BINARY_DIR}/vulkan-hpp-src")
        file(COPY "${CMAKE_BINARY_DIR}/vulkan-hpp-src/Vulkan-Hpp-${_vkhpp_version}/vulkan"
             DESTINATION "${CMAKE_CURRENT_SOURCE_DIR}/third_party")
        file(RENAME "${CMAKE_CURRENT_SOURCE_DIR}/third_party/vulkan" "${_vkhpp_root}")
    endif()

    set(VULKAN_HPP_DIR "${_vkhpp_root}" CACHE PATH "Vulkan-Hpp headers" FORCE)
endif()

set(CODEC_BUILD_TTS_CLI ON  CACHE BOOL "" FORCE)
set(CODEC_TTS_BACKBONE  ON  CACHE BOOL "" FORCE)
set(GGML_VULKAN         OFF CACHE BOOL "" FORCE)
set(CODEC_BACKBONE_VULKAN ${CHATTERBOX_VULKAN} CACHE BOOL "" FORCE)
set(CODEC_BACKBONE_METAL  ${CHATTERBOX_METAL}  CACHE BOOL "" FORCE)

if(APPLE)
    # codec.cpp's own ggml would otherwise also claim Metal, and two ggml
    # instances each holding a GPU backend is the configuration that segfaults
    # on Vulkan. Only the backbone gets an accelerator.
    set(GGML_METAL     OFF CACHE BOOL "" FORCE)
    set(GGML_ACCELERATE ON CACHE BOOL "" FORCE)
endif()

# ggml's x86 SIMD options are on by default and are not meaningful for arm64;
# NEON is what matters on a phone and is already the default there.
if(ANDROID OR IOS OR CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64")
    set(GGML_AVX    OFF CACHE BOOL "" FORCE)
    set(GGML_AVX2   OFF CACHE BOOL "" FORCE)
    set(GGML_AVX512 OFF CACHE BOOL "" FORCE)
    set(GGML_FMA    OFF CACHE BOOL "" FORCE)
    # SVE is not present on every arm64 phone and ggml probes it at compile
    # time, so a device without it would take an illegal instruction.
    set(GGML_SVE    OFF CACHE BOOL "" FORCE)
    set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
endif()

add_subdirectory("${CODEC_CPP_DIR}" codec_cpp EXCLUDE_FROM_ALL)

add_library(chatterbox_ffi SHARED src/chatterbox_ffi.cpp)

target_include_directories(chatterbox_ffi PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${CODEC_CPP_DIR}/include"
    "${CODEC_CPP_DIR}/common")

# codec_tts_runner holds the reference host loop; it must come in whole, since
# nothing in the shim references most of its translation units directly.
# codec-example-utils supplies the reference-WAV loader the runner calls for
# voice cloning (PCM 16-bit only — float WAVs are rejected).
#
# The backbone is linked by path, not by target name: codec.cpp produces it
# with a custom command rather than add_library, so `ttsbackbone` is a custom
# target that can only be depended on, never linked. Its own TTS_BACKBONE_SO
# variable is subdirectory-scoped and reads as empty here, so the path is
# reconstructed rather than borrowed.
if(APPLE)
    set(TTS_BACKBONE_SO "${CMAKE_BINARY_DIR}/ttsbackbone/libttsbackbone.dylib")
else()
    set(TTS_BACKBONE_SO "${CMAKE_BINARY_DIR}/ttsbackbone/libttsbackbone.so")
endif()
target_link_libraries(chatterbox_ffi PRIVATE
    $<$<PLATFORM_ID:Darwin,iOS>:codec_tts_runner>
    $<$<PLATFORM_ID:Darwin,iOS>:-Wl,-force_load,$<TARGET_FILE:codec_tts_runner>>
    $<$<NOT:$<PLATFORM_ID:Darwin,iOS>>:-Wl,--whole-archive>
    $<$<NOT:$<PLATFORM_ID:Darwin,iOS>>:codec_tts_runner>
    $<$<NOT:$<PLATFORM_ID:Darwin,iOS>>:-Wl,--no-whole-archive>
    codec_common
    codec-example-utils
    codec
    "${TTS_BACKBONE_SO}")

add_dependencies(chatterbox_ffi
    ttsbackbone
    codec_tts_runner
    codec_common
    codec-example-utils
    codec)

# The backbone is emitted by a custom command into its own directory, so the
# Android Gradle plugin never sees it and leaves it out of the APK — where it
# would fail at dlopen time on libchatterbox_ffi's DT_NEEDED entry. Copying it
# beside the shim puts it where AGP collects native libraries from.
if(ANDROID)
    add_custom_command(TARGET chatterbox_ffi POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${TTS_BACKBONE_SO}"
                "$<TARGET_FILE_DIR:chatterbox_ffi>/libttsbackbone.so"
        COMMENT "Staging libttsbackbone.so for packaging")
endif()

if(ANDROID)
    # ggml uses OpenMP where available and the NDK needs it named explicitly.
    find_library(ANDROID_LOG_LIB log)
    target_link_libraries(chatterbox_ffi PRIVATE ${ANDROID_LOG_LIB})
endif()

set_target_properties(chatterbox_ffi PROPERTIES
    OUTPUT_NAME "chatterbox_ffi"
    # The Dart side opens it by this exact soname.
    PREFIX "lib")

if(APPLE)
    set_target_properties(chatterbox_ffi PROPERTIES
        BUILD_RPATH "@loader_path"
        INSTALL_RPATH "@loader_path")
endif()
