import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var micStreamChannel: MicStreamChannel?

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
    }
  }
}
