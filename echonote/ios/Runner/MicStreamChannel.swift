import AVFoundation
import Flutter

/// Native mic capture for live transcription.
///
/// Controlled through MethodChannel `echonote/mic`; streams 16 kHz mono PCM16
/// little-endian chunks over EventChannel `echonote/mic/pcm`. The contract
/// (method names, error codes, chunk size) is defined in
/// docs/specs/feature-native-mic-stream/feature-native-mic-stream.md.
final class MicStreamChannel: NSObject, FlutterStreamHandler {
  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private var eventSink: FlutterEventSink?

  private let engine = AVAudioEngine()

  // Main thread only.
  private var isRunning = false
  /// Bumped on every start/stop, so chunks still queued for the main thread
  /// from an earlier session are dropped instead of sent after endOfStream.
  /// This means up to ~one chunk of tail audio is lost on stop.
  private var generation = 0

  // Audio (tap) thread only, except for the reset in `start` before the tap
  // is installed.
  private var converter: AVAudioConverter?
  private var pending = Data()

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(name: "echonote/mic", binaryMessenger: messenger)
    eventChannel = FlutterEventChannel(name: "echonote/mic/pcm", binaryMessenger: messenger)
    super.init()
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    eventChannel.setStreamHandler(self)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPermissionStatus":
      result(permissionStatus())
    case "requestPermission":
      requestPermission(result: result)
    case "start":
      start(args: call.arguments as? [String: Any], result: result)
    case "stop":
      stopCapture(sendEndOfStream: true)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Permission

  /// iOS never re-prompts after a denial, so `.denied` maps to
  /// `permanentlyDenied`; plain `denied` is only reported on Android.
  private func permissionStatus() -> String {
    if #available(iOS 17.0, *) {
      switch AVAudioApplication.shared.recordPermission {
      case .granted: return "granted"
      case .denied: return "permanentlyDenied"
      case .undetermined: return "undetermined"
      @unknown default: return "undetermined"
      }
    } else {
      switch AVAudioSession.sharedInstance().recordPermission {
      case .granted: return "granted"
      case .denied: return "permanentlyDenied"
      case .undetermined: return "undetermined"
      @unknown default: return "undetermined"
      }
    }
  }

  private func requestPermission(result: @escaping FlutterResult) {
    switch permissionStatus() {
    case "granted":
      result(true)
      return
    case "permanentlyDenied":
      result(false)
      return
    default:
      break
    }
    let completion: (Bool) -> Void = { granted in
      DispatchQueue.main.async { result(granted) }
    }
    if #available(iOS 17.0, *) {
      AVAudioApplication.requestRecordPermission(completionHandler: completion)
    } else {
      AVAudioSession.sharedInstance().requestRecordPermission(completion)
    }
  }

  // MARK: - Capture

  private func start(args: [String: Any]?, result: @escaping FlutterResult) {
    if isRunning {
      result(FlutterError(code: "ALREADY_RUNNING", message: "Mic stream is already running", details: nil))
      return
    }
    guard permissionStatus() == "granted" else {
      result(FlutterError(code: "PERMISSION_DENIED", message: "Microphone permission not granted", details: nil))
      return
    }
    let sampleRate = args?["sampleRate"] as? Int ?? 16000
    let chunkMs = args?["chunkMs"] as? Int ?? 100

    let session = AVAudioSession.sharedInstance()
    do {
      // Decision #6: keep the system voice processing (.default), no mixing.
      try session.setCategory(.playAndRecord, mode: .default, options: [])
      try session.setActive(true)
    } catch {
      result(FlutterError(code: "AUDIO_SESSION_ERROR", message: error.localizedDescription, details: nil))
      return
    }

    let input = engine.inputNode
    let inFormat = input.outputFormat(forBus: 0)
    guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
          let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true),
          let converter = AVAudioConverter(from: inFormat, to: outFormat)
    else {
      deactivateSession()
      result(FlutterError(
        code: "FORMAT_UNSUPPORTED",
        message: "Cannot convert \(inFormat) to \(sampleRate) Hz mono PCM16", details: nil))
      return
    }
    converter.downmix = true
    self.converter = converter
    pending = Data()

    // 2 bytes per sample, so always an even byte count.
    let chunkBytes = sampleRate * chunkMs / 1000 * 2
    generation += 1
    let gen = generation
    let tapFrames = AVAudioFrameCount(inFormat.sampleRate * Double(chunkMs) / 1000)
    input.installTap(onBus: 0, bufferSize: tapFrames, format: inFormat) { [weak self] buffer, _ in
      self?.process(buffer, outFormat: outFormat, chunkBytes: chunkBytes, generation: gen)
    }

    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      deactivateSession()
      result(FlutterError(code: "AUDIO_SESSION_ERROR", message: error.localizedDescription, details: nil))
      return
    }
    isRunning = true
    result(nil)
  }

  /// Runs on the tap's audio thread: converts the hardware buffer to PCM16,
  /// then hands fixed-size chunks to the main thread for the event sink.
  private func process(
    _ buffer: AVAudioPCMBuffer, outFormat: AVAudioFormat, chunkBytes: Int, generation gen: Int
  ) {
    guard let converter = converter else { return }
    let ratio = outFormat.sampleRate / buffer.format.sampleRate
    // Headroom for frames the resampler held back from the previous buffer.
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

    var consumed = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, inputStatus in
      if consumed {
        inputStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, out.frameLength > 0, let samples = out.int16ChannelData else { return }
    pending.append(UnsafeBufferPointer(start: samples[0], count: Int(out.frameLength)))

    while pending.count >= chunkBytes {
      let chunk = Data(pending.prefix(chunkBytes))
      pending.removeFirst(chunkBytes)
      DispatchQueue.main.async { [weak self] in
        guard let self = self, self.isRunning, self.generation == gen else { return }
        self.eventSink?(FlutterStandardTypedData(bytes: chunk))
      }
    }
  }

  /// Idempotent: calling it while not running does nothing.
  private func stopCapture(sendEndOfStream: Bool) {
    guard isRunning else { return }
    isRunning = false
    generation += 1
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    deactivateSession()
    if sendEndOfStream {
      eventSink?(FlutterEndOfEventStream)
    }
  }

  private func deactivateSession() {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  /// The Dart side stopped listening: release the mic rather than keep
  /// recording into nowhere.
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stopCapture(sendEndOfStream: false)
    eventSink = nil
    return nil
  }
}
