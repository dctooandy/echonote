cmake_minimum_required(VERSION 3.22)
project(echo_core_jni C)

# The same echo_core.c as the Flutter build hook, with the same flags, so
# results match the Dart and Swift wrappers bit for bit.
set(ECHO_CORE_SRC ${CMAKE_CURRENT_SOURCE_DIR}/../../../../src)

add_library(echo_core_jni SHARED
    ${ECHO_CORE_SRC}/echo_core.c
    echo_core_jni.c
)
target_include_directories(echo_core_jni PRIVATE ${ECHO_CORE_SRC})
set_target_properties(echo_core_jni PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED ON)
target_compile_options(echo_core_jni PRIVATE -O3 -Wall -Wextra -Werror -ffp-contract=off)
