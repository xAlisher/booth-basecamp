cmake_minimum_required(VERSION 3.14)
project(RadioModulePlugin LANGUAGES CXX)

# Include the Logos Module CMake helper (provided by logos-module-builder)
if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found. Set LOGOS_MODULE_BUILDER_ROOT.")
endif()

find_package(PkgConfig REQUIRED)
pkg_check_modules(secp256k1 REQUIRED IMPORTED_TARGET libsecp256k1)   # #24 station-identity signing

logos_module(
    NAME radio_module
    SOURCES
        src/radio_interface.h
        src/radio_plugin.h
        src/radio_plugin.cpp
        src/station_identity.h
        src/station_identity.cpp
    FIND_PACKAGES
        Qt6
    LINK_LIBRARIES
        PkgConfig::secp256k1
)

# Tests are NOT wired through CMake. The builder's #unit-tests targets the tutorial's _impl
# module style (logos_test()), which doesn't fit our _plugin/QObject module. Instead:
#   - tests/run-direct-test.sh  — Tier-1 in-process proof (instantiate plugin, call methods)
#   - tests/run-headless-tests.sh — logoscore load/dispatch smoke
# See docs/plans/radio-implementation.md (headless-testing strategy).
