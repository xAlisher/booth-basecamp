cmake_minimum_required(VERSION 3.14)
project(RadioUiPlugin LANGUAGES CXX)

if(DEFINED ENV{LOGOS_MODULE_BUILDER_ROOT})
    include($ENV{LOGOS_MODULE_BUILDER_ROOT}/cmake/LogosModule.cmake)
else()
    message(FATAL_ERROR "LogosModule.cmake not found. Set LOGOS_MODULE_BUILDER_ROOT.")
endif()

logos_module(
    NAME radio_ui
    REP_FILE src/radio_ui.rep
    SOURCES
        src/radio_ui_backend.h
        src/radio_ui_backend.cpp
    INCLUDE_DIRS
        src
)
