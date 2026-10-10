package com.echonote.echocore

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin

/** Same cases as the Swift tests (swift/Tests/EchoCoreTests). */
@RunWith(AndroidJUnit4::class)
class EchoCoreJniTest {
    /** A 100 ms chunk (1600 samples at 16 kHz) of a 440 Hz tone at [level]. */
    private fun chunk(level: Double, index: Int) = ShortArray(1600) { i ->
        val t = (index * 1600 + i) / 16000.0
        (level * 32767 * sin(2 * PI * 440 * t)).roundToInt().toShort()
    }

    @Test
    fun rms() {
        assertEquals(0.5f, EchoCoreJni.rms(shortArrayOf(16384, -16384, 16384, -16384)))
        assertEquals(1f, EchoCoreJni.rms(shortArrayOf(-32768)))
        assertEquals(0f, EchoCoreJni.rms(ShortArray(0)))
    }

    @Test
    fun vadQuietSpeechQuiet() {
        EchoVad().use { vad ->
            val decisions = (0 until 10).map { vad.process(chunk(0.0005, it)) } +
                (10 until 20).map { vad.process(chunk(0.2, it)) } +
                (20 until 30).map { vad.process(chunk(0.0005, it)) }
            assertEquals(List(10) { false } + List(10) { true } + List(10) { false }, decisions)
            assertFalse(vad.process(ShortArray(0)))
        }
    }

    @Test
    fun closeTwiceThenUseThrows() {
        val vad = EchoVad()
        vad.close()
        vad.close()
        assertThrows(IllegalStateException::class.java) { vad.process(chunk(0.2, 0)) }
    }

    @Test
    fun zeroHandleIsSafe() {
        assertFalse(EchoCoreJni.vadProcess(0, chunk(0.2, 0)))
        EchoCoreJni.vadDestroy(0)
    }
}
