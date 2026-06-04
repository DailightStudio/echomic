cmake_minimum_required(VERSION 3.18.1)

project(echomic_engine LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# --- Oboe (fetched at configure time) ---
include(FetchContent)
FetchContent_Declare(
        oboe
        GIT_REPOSITORY https://github.com/google/oboe.git
        GIT_TAG        1.9.0
)
FetchContent_MakeAvailable(oboe)

# --- Native audio engine shared library loaded by the JVM ---
add_library(echomic_engine SHARED
        jni_bridge.cpp
        audio_engine.cpp)

target_include_directories(echomic_engine PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

find_library(log-lib log)

target_link_libraries(echomic_engine
        oboe
        android
        ${log-lib})

# Release optimization for the real-time audio path.
target_compile_options(echomic_engine PRIVATE
        $<$<CONFIG:Release>:-O3>
        -Wall)
