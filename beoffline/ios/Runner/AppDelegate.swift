import UIKit
import Flutter
import FamilyControls
import ManagedSettings
import DeviceActivity
import SwiftUI

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let CHANNEL = "beoffline/ios_screentime"
  private let screenTimeManager = ScreenTimeManager.shared

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    let channel = FlutterMethodChannel(name: CHANNEL, binaryMessenger: controller.binaryMessenger)
    
    // Rejestracja widoku raportów (UiKitView)
    let factory = ScreenTimeReportFactory(messenger: controller.binaryMessenger)
    registrar(forPlugin: "ScreenTimeReport")?.register(factory, withId: "beoffline/report")

    channel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else { return }
      
      switch call.method {
      case "authStatus":
        if #available(iOS 16.0, *) {
          result(AuthorizationCenter.shared.authorizationStatus == .approved)
        } else { result(false) }
        
      case "requestAuth":
        if #available(iOS 16.0, *) {
          Task {
            do {
              try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
              result(true)
            } catch { result(FlutterError(code: "AUTH_ERR", message: error.localizedDescription, details: nil)) }
          }
        } else { result(false) }

      case "hasDeviceSelection":
        result(self.screenTimeManager.hasDeviceSelection)

      case "pickDeviceSelection":
        self.screenTimeManager.pickDeviceSelection { result(nil) }

      case "setDeviceSettings":
        let args = call.arguments as! [String: Any]
        self.screenTimeManager.setDeviceSettings(minutes: args["limitMinutes"] as! Int, notifications: args["notifications"] as! Bool)
        result(nil)

      case "pickLimitApps":
        let args = call.arguments as? [String: Any]
        let id = args?["id"] as? String
        self.screenTimeManager.pickLimitApps(existingId: id) { newId in
          result(newId)
        }

      case "saveLimit":
        let args = call.arguments as! [String: Any]
        self.screenTimeManager.saveLimit(
          id: args["id"] as! String,
          daily: args["daily"] as! Int,
          session: args["session"] as! Int,
          wait: args["wait"] as! Int,
          result: result
        )

      case "removeLimit":
        let args = call.arguments as! [String: Any]
        self.screenTimeManager.removeLimit(id: args["id"] as! String)
        result(nil)

      case "getLimits":
        result(self.screenTimeManager.getLimits())

      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}