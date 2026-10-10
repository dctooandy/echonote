#!/bin/sh
# Builds vad_eval on macOS from the app's own sources: the vendored
# whisper.cpp (packages/whisper_ggml) and echo_core (packages/echo_core),
# with the same defines the iOS podspec uses. Objects are cached in build/.
set -eu
cd "$(dirname "$0")"
W=../../packages/whisper_ggml/ios/Classes/whisper
E=../../packages/echo_core/src
OUT=build
mkdir -p "$OUT/obj"

DEFS='-DGGML_USE_CPU=1 -DGGML_USE_ACCELERATE=1 -DACCELERATE_NEW_LAPACK=1 -DACCELERATE_LAPACK_ILP64=1 -DGGML_VERSION=\"1.9.1\" -DGGML_COMMIT=\"whisper.cpp-v1.9.1\" -DWHISPER_VERSION=\"1.9.1\"'
INC="-I$W/include -I$W/ggml/include -I$W/ggml/src -I$W/ggml/src/ggml-cpu -I$W/src -I$W/examples -I$E"

objs=""
for src in $(find "$W/src" "$W/ggml/src" -name '*.c' -o -name '*.cpp') "$E/echo_core.c" vad_eval.cpp; do
  obj="$OUT/obj/$(echo "$src" | tr '/.' '__').o"
  objs="$objs $obj"
  [ "$obj" -nt "$src" ] && [ "$src" != vad_eval.cpp ] && continue
  case "$src" in
    *.c) eval clang -std=c11 -O3 -ffp-contract=off $DEFS $INC -c "$src" -o "$obj" ;;
    *)   eval clang++ -std=c++20 -O3 $DEFS $INC -c "$src" -o "$obj" ;;
  esac
done
clang++ $objs -framework Accelerate -o "$OUT/vad_eval"
echo "built $OUT/vad_eval"
