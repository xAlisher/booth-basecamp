# Standalone build of tests/playlist_test.cpp (Qt Core + Network only, no Logos SDK). Driven by tests/run-playlist-test.sh.
cmake_minimum_required(VERSION 3.16)
project(radio_playlist_test LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 REQUIRED COMPONENTS Core Network)
set(SRC ${CMAKE_CURRENT_LIST_DIR}/../../src)
add_executable(playlist_test
    ${CMAKE_CURRENT_LIST_DIR}/../playlist_test.cpp
    ${SRC}/playlist_source.h ${SRC}/playlist_source.cpp
    ${SRC}/child_guard.h ${SRC}/child_guard.cpp)
target_include_directories(playlist_test PRIVATE ${SRC})
target_link_libraries(playlist_test PRIVATE Qt6::Core Qt6::Network)
