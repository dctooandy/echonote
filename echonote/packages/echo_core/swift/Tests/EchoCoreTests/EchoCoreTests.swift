import CEchoCore
import EchoCore
import Foundation
import XCTest

/// A 100 ms chunk (1600 samples at 16 kHz) of a 440 Hz tone at `level`.
private func chunk(_ level: Double, _ index: Int) -> [Int16] {
    (0..<1600).map { i in
        let t = Double(index * 1600 + i) / 16000
        return Int16((level * 32767 * sin(2 * .pi * 440 * t)).rounded())
    }
}

final class EchoCoreTests: XCTestCase {
    func testPcm16ToFloat() {
        XCTAssertEqual(EchoCore.pcm16ToFloat([-32768, 0, 16384, 32767]),
                       [-1, 0, 0.5, Float(32767) / 32768])
        XCTAssertEqual(EchoCore.pcm16ToFloat([]), [])
    }

    func testRms() {
        XCTAssertEqual(EchoCore.rms([16384, -16384, 16384, -16384]), 0.5)
        XCTAssertEqual(EchoCore.rms([-32768]), 1)
        XCTAssertEqual(EchoCore.rms([]), 0)
    }

    func testWaveform() {
        XCTAssertEqual(EchoCore.waveform([0, 8192, -16384, 0], buckets: 2), [0.25, 0.5])
        XCTAssertEqual(EchoCore.waveform([16384, -32768], buckets: 5), [0.5, 1])
        XCTAssertEqual(EchoCore.waveform([1, 2], buckets: 0), [])
        XCTAssertEqual(EchoCore.waveform([], buckets: 4), [])
    }

    func testVadQuietSpeechQuiet() throws {
        let vad = try XCTUnwrap(EchoVAD())
        var decisions: [Bool] = []
        for i in 0..<10 { decisions.append(vad.process(chunk(0.0005, i))) }
        for i in 10..<20 { decisions.append(vad.process(chunk(0.2, i))) }
        for i in 20..<30 { decisions.append(vad.process(chunk(0.0005, i))) }
        XCTAssertEqual(decisions, Array(repeating: false, count: 10)
                       + Array(repeating: true, count: 10)
                       + Array(repeating: false, count: 10))
        XCTAssertFalse(vad.process([]))
    }

    func testVadDefaultsMatchTheHeader() {
        let c = ec_vad_default_config()
        XCTAssertEqual(c.initial_noise_floor, 0.005)
        XCTAssertEqual(c.voice_ratio, 2.5)
    }

    func testVadIsFreedWhenReleased() throws {
        // Nothing to observe from Swift; this runs deinit under the test
        // process so a double free or crash would fail the run.
        var vad: EchoVAD? = try XCTUnwrap(EchoVAD())
        _ = vad?.process(chunk(0.2, 0))
        vad?.reset()
        vad = nil
        XCTAssertNil(vad)
    }
}
