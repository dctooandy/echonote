import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var micStreamChannel: MicStreamChannel?
  private var screenAwakeChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // With the implicit engine there is no rootViewController to take a
    // messenger from; borrow one from a registrar instead.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MicStreamChannel") {
      micStreamChannel = MicStreamChannel(messenger: registrar.messenger())
      screenAwakeChannel = makeScreenAwakeChannel(messenger: registrar.messenger())
    }
  }
}

/// `echonote/screen`: keeps the screen from auto-locking while recording or
/// transcribing, which stop when the app leaves the foreground (spec
/// feature-keep-screen-awake). Lives here rather than in its own file to
/// avoid an Xcode project change for a few lines.
private func makeScreenAwakeChannel(messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
  let channel = FlutterMethodChannel(name: "echonote/screen", binaryMessenger: messenger)
  channel.setMethodCallHandler { call, result in
    guard call.method == "setKeepAwake", let on = call.arguments as? Bool else {
      result(FlutterMethodNotImplemented)
      return
    }
    UIApplication.shared.isIdleTimerDisabled = on
    result(nil)
  }
  return channel
}
