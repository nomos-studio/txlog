# SPDX-License-Identifier: BSL-1.0
cmake_minimum_required(VERSION 3.20)

project(txlog-cpp
    VERSION 0.1.0
    DESCRIPTION "txlog-cpp — C++ library for reading and writing the cljseq transaction log"
    HOMEPAGE_URL "https://github.com/cljseq/txlog-cpp"
    LANGUAGES CXX)

# ---------------------------------------------------------------------------
# Dependency policy (mirrors cljseq native convention)
#
# - No Boost. C++20 STL covers all use cases.
# - FetchContent + pinned tag for any dependency with a build step.
# - FETCHCONTENT_UPDATES_DISCONNECTED: skip network on subsequent invocations.
# - Tests use Catch2 v3 (Boost Software License, header-friendly).
# - SQLite3 via find_package — available on all target platforms.
# ---------------------------------------------------------------------------

include(FetchContent)
include(CMakePackageConfigHelpers)
include(GNUInstallDirs)

set(FETCHCONTENT_UPDATES_DISCONNECTED ON CACHE BOOL
    "Skip network fetch if already populated")

# ---------------------------------------------------------------------------
# Build options
# ---------------------------------------------------------------------------

option(TXLOG_CPP_BUILD_TESTS    "Build txlog-cpp unit tests"  OFF)
option(TXLOG_CPP_BUILD_EXAMPLES "Build txlog-cpp examples"    OFF)
option(TXLOG_CPP_INSTALL        "Generate install targets"    ON)

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

# SQLite3 — system package on all target platforms.
find_package(SQLite3 REQUIRED)

# edn-cpp — FetchContent with optional local override for development.
#   To use a local checkout: cmake -DEDN_CPP_DIR=/path/to/edn-cpp ...
if(DEFINED EDN_CPP_DIR)
    FetchContent_Declare(edn-cpp SOURCE_DIR "${EDN_CPP_DIR}")
else()
    FetchContent_Declare(edn-cpp
        GIT_REPOSITORY https://github.com/cljseq/edn-cpp.git
        GIT_TAG        v0.1.0
        GIT_SHALLOW    TRUE)
endif()
set(EDN_CPP_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(EDN_CPP_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(edn-cpp)

# ---------------------------------------------------------------------------
# Library target
# ---------------------------------------------------------------------------

add_library(txlog-cpp
    src/txlog.cpp
)

add_library(txlog::txlog ALIAS txlog-cpp)

target_include_directories(txlog-cpp
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
    PRIVATE
        src
)

target_link_libraries(txlog-cpp
    PUBLIC  edn::edn
    PRIVATE SQLite3::SQLite3
)

set_target_properties(txlog-cpp PROPERTIES
    CXX_STANDARD          20
    CXX_STANDARD_REQUIRED ON
    CXX_EXTENSIONS        OFF
    VERSION               ${PROJECT_VERSION}
    SOVERSION             0
    EXPORT_NAME           txlog
)

# ---------------------------------------------------------------------------
# Compiler warnings (opt-in; does not affect consumers)
# ---------------------------------------------------------------------------

if(CMAKE_PROJECT_NAME STREQUAL PROJECT_NAME)
    target_compile_options(txlog-cpp PRIVATE
        $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-Wall -Wextra -Wpedantic -Werror>
        $<$<CXX_COMPILER_ID:MSVC>:/W4 /WX>
    )
endif()

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

if(TXLOG_CPP_BUILD_TESTS)
    enable_testing()

    # Catch2 v3 — BSL-1.0, header-friendly, no extra dependencies.
    # Pin: v3.7.1 — update deliberately and document the reason.
    FetchContent_Declare(Catch2
        GIT_REPOSITORY https://github.com/catchorg/Catch2.git
        GIT_TAG        v3.7.1
        GIT_SHALLOW    TRUE)
    FetchContent_MakeAvailable(Catch2)

    add_subdirectory(tests)
endif()

# ---------------------------------------------------------------------------
# Install + package export
# ---------------------------------------------------------------------------

if(TXLOG_CPP_INSTALL)
    install(TARGETS txlog-cpp
        EXPORT  txlog-cpp-targets
        ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
        LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
        RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    )

    install(DIRECTORY include/txlog
        DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
    )

    install(EXPORT txlog-cpp-targets
        FILE        txlog-cpp-targets.cmake
        NAMESPACE   txlog::
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/txlog-cpp
    )

    configure_package_config_file(
        cmake/txlog-cpp-config.cmake.in
        ${CMAKE_CURRENT_BINARY_DIR}/txlog-cpp-config.cmake
        INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/txlog-cpp
    )

    write_basic_package_version_file(
        ${CMAKE_CURRENT_BINARY_DIR}/txlog-cpp-config-version.cmake
        VERSION       ${PROJECT_VERSION}
        COMPATIBILITY SameMajorVersion
    )

    install(FILES
        ${CMAKE_CURRENT_BINARY_DIR}/txlog-cpp-config.cmake
        ${CMAKE_CURRENT_BINARY_DIR}/txlog-cpp-config-version.cmake
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/txlog-cpp
    )
endif()
