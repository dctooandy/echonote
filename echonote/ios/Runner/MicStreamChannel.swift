import AVFoundation
import Flutter
import UIKit

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

  /// Target format and chunk size of the running stream, kept for
  /// reinstalling the tap after a hardware format change.
  private var outFormat: AVAudioFormat?
  private var chunkMs = 100
  private var observers: [NSObjectProtocol] = []

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
    case "openSettings":
      // Lets the user grant the mic after a denial; iOS never re-prompts.
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url) { opened in result(opened) }
      } else {
        result(false)
      }
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
    chunkMs = args?["chunkMs"] as? Int ?? 100

    let session = AVAudioSession.sharedInstance()
    do {
      // Decision #6: keep the system voice processing (.default), no mixing.
      try session.setCategory(.playAndRecord, mode: .default, options: [])
      try session.setActive(true)
    } catch {
      result(FlutterError(code: "AUDIO_SESSION_ERROR", message: error.localizedDescription, details: nil))
      return
    }

    guard let outFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true)
    else {
      deactivateSession()
      result(FlutterError(
        code: "FORMAT_UNSUPPORTED", message: "Invalid sample rate \(sampleRate)", details: nil))
      return
    }
    self.outFormat = outFormat
    generation += 1

    if let error = installTapAndStart() {
      deactivateSession()
      result(error)
      return
    }
    isRunning = true
    addObservers()
    result(nil)
  }

  /// Installs a tap converting the input node's *current* hardware format and
  /// starts the engine. Used on start and again after a format change.
  private func installTapAndStart() -> FlutterError? {
    guard let outFormat = outFormat else {
      return FlutterError(code: "FORMAT_UNSUPPORTED", message: "No target format", details: nil)
    }
    let input = engine.inputNode
    let inFormat = input.outputFormat(forBus: 0)
    guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
          let pipeline = TapPipeline(from: inFormat, to: outFormat, chunkMs: chunkMs)
    else {
      return FlutterError(
        code: "FORMAT_UNSUPPORTED",
        message: "Cannot convert \(inFormat) to \(outFormat.sampleRate) Hz mono PCM16", details: nil)
    }

    let gen = generation
    let tapFrames = AVAudioFrameCount(inFormat.sampleRate * Double(chunkMs) / 1000)
    // The pipeline is owned by this tap's closure alone, so a reinstall never
    // races the audio thread over converter state.
    input.installTap(onBus: 0, bufferSize: tapFrames, format: inFormat) { [weak self] buffer, _ in
      for chunk in pipeline.process(buffer) {
        DispatchQueue.main.async {
          guard let self = self, self.isRunning, self.generation == gen else { return }
          self.eventSink?(FlutterStandardTypedData(bytes: chunk))
        }
      }
    }

    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      return FlutterError(code: "AUDIO_SESSION_ERROR", message: error.localizedDescription, details: nil)
    }
    return nil
  }

  // MARK: - System events

  private func addObservers() {
    let center = NotificationCenter.default
    observers = [
      // Plugging/unplugging headphones or Bluetooth can change the hardware
      // format; the engine stops itself and the tap must be rebuilt.
      center.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
      ) { [weak self] _ in
        self?.handleConfigurationChange()
      },
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(), queue: .main
      ) { [weak self] note in
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began
        else { return }
        // Decision #11: no auto-resume; end and let Dart save what we have.
        self?.endWithError(code: "INTERRUPTED", message: "Audio session interrupted")
      },
      center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
      ) { [weak self] _ in
        // Decision #5: no background recording.
        self?.endWithError(code: "BACKGROUNDED", message: "App entered the background")
      },
    ]
  }

  private func removeObservers() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
  }

  private func handleConfigurationChange() {
    guard isRunning else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    // Same generation: chunks already queued still belong to this stream.
    // Up to one partial chunk buffered in the old pipeline is dropped.
    if let error = installTapAndStart() {
      endWithError(code: error.code, message: error.message ?? "")
    }
  }

  /// Sends a stream error, then ends the stream (error first, then
  /// endOfStream, as the contract specifies).
  private func endWithError(code: String, message: String) {
    guard isRunning else { return }
    eventSink?(FlutterError(code: code, message: message, details: nil))
    stopCapture(sendEndOfStream: true)
  }

  /// Idempotent: calling it while not running does nothing.
  private func stopCapture(sendEndOfStream: Bool) {
    guard isRunning else { return }
    isRunning = false
    generation += 1
    removeObservers()
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

/// Converts hardware buffers to PCM16 at the target rate and cuts them into
/// fixed-size chunks. Lives on the tap's audio thread only.
private final class TapPipeline {
  private let converter: AVAudioConverter
  private let outFormat: AVAudioFormat
  private let chunkBytes: Int
  private var pending = Data()

  init?(from inFormat: AVAudioFormat, to outFormat: AVAudioFormat, chunkMs: Int) {
    guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }
    converter.downmix = true
    self.converter = converter
    self.outFormat = outFormat
    // 2 bytes per sample, so always an even byte count.
    chunkBytes = Int(outFormat.sampleRate) * chunkMs / 1000 * 2
  }

  func process(_ buffer: AVAudioPCMBuffer) -> [Data] {
    let ratio = outFormat.sampleRate / buffer.format.sampleRate
    // Headroom for frames the resampler held back from the previous buffer.
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return [] }

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
    guard status != .error, out.frameLength > 0, let samples = out.int16ChannelData else { return [] }
    pending.append(UnsafeBufferPointer(start: samples[0], count: Int(out.frameLength)))

    var chunks: [Data] = []
    while pending.count >= chunkBytes {
      chunks.append(Data(pending.prefix(chunkBytes)))
      pending.removeFirst(chunkBytes)
    }
    return chunks
  }
}
