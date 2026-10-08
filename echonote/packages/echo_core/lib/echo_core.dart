/// echonote's cross-platform C audio core, called through dart:ffi.
///
/// The top-level functions pass Dart memory to C without copying; see
/// [EchoBufferedCore] for the copy-into-native-memory path and
/// [DartReference] for the pure-Dart versions used in tests and benchmarks.
library;

export 'src/native.dart';
export 'src/reference.dart';
export 'src/vad_config.dart';
