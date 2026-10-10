// JNI bridge: Kotlin's EchoCoreJni -> echo_core's C functions.
//
// Arrays go to C with GetPrimitiveArrayCritical: no copy (usually), but
// between Get and Release the code must be short and call no other JNI
// function — the same contract as a dart:ffi leaf call. echo_core's
// functions qualify: they are short and never call back.
#include <jni.h>
#include <stdint.h>

#include "echo_core.h"

#define FN(name) Java_com_echonote_echocore_EchoCoreJni_##name

JNIEXPORT jfloat JNICALL FN(rms)(JNIEnv *env, jobject self, jshortArray samples) {
    (void)self;
    const jsize n = (*env)->GetArrayLength(env, samples);
    if (n == 0) return 0.0f;
    jshort *p = (*env)->GetPrimitiveArrayCritical(env, samples, NULL);
    if (p == NULL) return 0.0f;  // OutOfMemoryError is pending in Kotlin
    const float level = ec_rms_pcm16((const int16_t *)p, n);
    // JNI_ABORT: read-only, nothing to copy back.
    (*env)->ReleasePrimitiveArrayCritical(env, samples, p, JNI_ABORT);
    return level;
}

// The ec_vad pointer travels to Kotlin as a jlong handle; 0 means failure.
JNIEXPORT jlong JNICALL FN(vadCreate)(JNIEnv *env, jobject self) {
    (void)env;
    (void)self;
    return (jlong)(intptr_t)ec_vad_create(ec_vad_default_config());
}

JNIEXPORT jboolean JNICALL FN(vadProcess)(JNIEnv *env, jobject self, jlong handle,
                                          jshortArray samples) {
    (void)self;
    ec_vad *vad = (ec_vad *)(intptr_t)handle;
    const jsize n = (*env)->GetArrayLength(env, samples);
    if (vad == NULL || n == 0) return JNI_FALSE;
    jshort *p = (*env)->GetPrimitiveArrayCritical(env, samples, NULL);
    if (p == NULL) return JNI_FALSE;
    const int32_t voiced = ec_vad_process(vad, (const int16_t *)p, n);
    (*env)->ReleasePrimitiveArrayCritical(env, samples, p, JNI_ABORT);
    return voiced == 1 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL FN(vadDestroy)(JNIEnv *env, jobject self, jlong handle) {
    (void)env;
    (void)self;
    ec_vad_destroy((ec_vad *)(intptr_t)handle);
}
