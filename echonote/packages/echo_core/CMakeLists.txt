# Shared library for the C# (P/Invoke) wrapper in dotnet/: the same
# src/echo_core.cpp as the Flutter build hook, with the same flags, so
# results match the Dart, Swift and Kotlin wrappers.
cmake_minimum_required(VERSION 3.20)
project(echo_core CXX)

add_library(echo_core SHARED src/echo_core.cpp)
set_target_properties(echo_core PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    CXX_EXTENSIONS OFF
    CXX_VISIBILITY_PRESET hidden
    # Static C++ runtime on Windows: callers need no VC++ redistributable.
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

if(MSVC)
    # MSVC has no -ffp-contract=off; its default /fp:precise does not fuse
    # multiply-adds either. /EHsc: standard C++ exception model (the core
    # throws nothing; see src/echo_core.cpp).
    target_compile_options(echo_core PRIVATE /O2 /W4 /WX /EHsc)
else()
    target_compile_options(echo_core PRIVATE -O3 -Wall -Wextra -Werror -ffp-contract=off)
endif()
