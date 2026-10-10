package com.echonote.echocore

/**
 * Raw JNI bindings to echo_core (the same C the Flutter app calls through
 * dart:ffi). Arrays are passed without copying; see echo_core_jni.c.
 */
object EchoCoreJni {
    init {
        System.loadLibrary("echo_core_jni")
    }

    /** Normalized RMS level, 0..1. */
    external fun rms(samples: ShortArray): Float

    /** Native ec_vad handle with default config; 0 if allocation failed. */
    external fun vadCreate(): Long

    /** True when [samples] is voiced. Empty input returns false. */
    external fun vadProcess(handle: Long, samples: ShortArray): Boolean

    /** Frees the handle; 0 is a no-op. */
    external fun vadDestroy(handle: Long)
}

/**
 * Energy-gate VAD over a native ec_vad. Kotlin has no deterministic
 * destructor, so release it with [close] (or `use { }`), like the Dart
 * EchoVad's dispose(). Not thread-safe.
 */
class EchoVad : AutoCloseable {
    private var handle: Long = EchoCoreJni.vadCreate()

    init {
        check(handle != 0L) { "ec_vad_create failed: out of memory" }
    }

    fun process(samples: ShortArray): Boolean {
        check(handle != 0L) { "EchoVad is closed" }
        return EchoCoreJni.vadProcess(handle, samples)
    }

    /** Safe to call twice. */
    override fun close() {
        if (handle == 0L) return
        EchoCoreJni.vadDestroy(handle)
        handle = 0L
    }
}
