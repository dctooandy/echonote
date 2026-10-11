# Shared library for the C# (P/Invoke) wrapper in dotnet/: the same
# src/echo_core.c as the Flutter build hook, with the same flags, so results
# match the Dart, Swift and Kotlin wrappers.
cmake_minimum_required(VERSION 3.20)
project(echo_core C)

add_library(echo_core SHARED src/echo_core.c)
set_target_properties(echo_core PROPERTIES
    C_STANDARD 11
    C_STANDARD_REQUIRED ON
    C_VISIBILITY_PRESET hidden)

if(MSVC)
    # MSVC has no -ffp-contract=off; its default /fp:precise does not fuse
    # multiply-adds either.
    target_compile_options(echo_core PRIVATE /O2 /W4 /WX)
else()
    target_compile_options(echo_core PRIVATE -O3 -Wall -Wextra -Werror -ffp-contract=off)
    target_link_libraries(echo_core PRIVATE m)
endif()
