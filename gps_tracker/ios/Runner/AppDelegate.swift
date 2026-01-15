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
    // Google Maps API Key for Employee History feature (Spec 006)
    GMSServices.provideAPIKey("AIzaSyCH-YBkJy4ggJ8qsFj7PEY49GylnAZysBo")

    GeneratedPluginRegistrant.register(with: self)

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
