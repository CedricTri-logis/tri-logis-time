import Flutter
import UIKit
import flutter_foreground_task
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Google Maps API Key (loaded from Secrets.xcconfig via Info.plist)
    if let apiKey = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_MAPS_API_KEY") as? String, !apiKey.isEmpty {
      GMSServices.provideAPIKey(apiKey)
    }

    GeneratedPluginRegistrant.register(with: self)

    // Register Significant Location Change plugin (safety net for terminated app)
    SignificantLocationPlugin.register(with: self.registrar(forPlugin: "SignificantLocationPlugin")!)

    // Register Background Task plugin (CLBackgroundActivitySession + beginBackgroundTask + thermal)
    BackgroundTaskPlugin.register(with: self.registrar(forPlugin: "BackgroundTaskPlugin")!)

    // Required for flutter_foreground_task
    SwiftFlutterForegroundTaskPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }

    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
