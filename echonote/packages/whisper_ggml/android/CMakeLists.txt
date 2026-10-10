# [echonote] Android build of the same sources iOS compiles. CocoaPods can
# only reach files under ios/, CMake can reach anywhere, so the sources stay
# in ios/Classes and this file points there (one copy for both platforms).
# Upstream 2.4.0 shipped a second copy of whisper.cpp under android/.
cmake_minimum_required(VERSION 3.10)

project(whisper_flutter_library LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 20)  # same as the podspec
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(CLASSES ${CMAKE_CURRENT_SOURCE_DIR}/../ios/Classes)
set(W ${CLASSES}/whisper)

# whisper.cpp v1.9.1, CPU backend only. The arch/ sources are guarded per
# architecture, so the x86 files compile to nothing on arm64.
file(GLOB GGML_SRC
    ${W}/ggml/src/*.c
    ${W}/ggml/src/*.cpp
    ${W}/ggml/src/ggml-cpu/*.c
    ${W}/ggml/src/ggml-cpu/*.cpp
    ${W}/ggml/src/ggml-cpu/arch/arm/*.c
    ${W}/ggml/src/ggml-cpu/arch/arm/*.cpp
    ${W}/ggml/src/ggml-cpu/arch/x86/*.c
    ${W}/ggml/src/ggml-cpu/arch/x86/*.cpp
    ${W}/ggml/src/ggml-cpu/amx/*.cpp
)

add_library(whisper STATIC ${GGML_SRC} ${W}/src/whisper.cpp)
target_include_directories(whisper PUBLIC
    ${W}/include
    ${W}/ggml/include
    ${W}/ggml/src
    ${W}/ggml/src/ggml-cpu
    ${W}/src
)
target_compile_definitions(whisper PUBLIC GGML_USE_CPU)
target_compile_definitions(whisper PRIVATE
    GGML_VERSION="1.9.1"
    GGML_COMMIT="whisper.cpp-v1.9.1"
    WHISPER_VERSION="1.9.1"
)
# No -march override: baseline armv8-a runs everywhere (upstream issue #15).
target_compile_options(whisper PRIVATE -O3 -ffunction-sections -fdata-sections)

# The FFI entry points (request, stream_start/feed/stop, ...) live in the
# same file iOS compiles, with every echonote change.
add_library(whisper_flutter SHARED ${CLASSES}/whisper_flutter_plus.cpp)
set_target_properties(whisper_flutter PROPERTIES OUTPUT_NAME "whisper")
target_compile_options(whisper_flutter PRIVATE -O3 -ffunction-sections -fdata-sections)
target_link_options(whisper_flutter PRIVATE -Wl,--gc-sections)
find_package(Threads REQUIRED)
target_link_libraries(whisper_flutter PRIVATE whisper Threads::Threads)
