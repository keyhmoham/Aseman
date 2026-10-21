import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pendingPushTokenResult: FlutterResult?
  private let pushTokenKey = "aseman.apns.token"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "AsemanPushNotifications"
    )
    let channel = FlutterMethodChannel(
      name: "aseman/push_notifications",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "requestToken":
        self.requestPushToken(result)
      case "currentToken":
        result(UserDefaults.standard.string(forKey: self.pushTokenKey))
      case "unregister":
        UIApplication.shared.unregisterForRemoteNotifications()
        UserDefaults.standard.removeObject(forKey: self.pushTokenKey)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func requestPushToken(_ result: @escaping FlutterResult) {
    guard pendingPushTokenResult == nil else {
      result(FlutterError(
        code: "request_in_progress",
        message: "A push-token request is already active",
        details: nil
      ))
      return
    }
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .badge, .sound]
    ) { [weak self] granted, error in
      guard let self else { return }
      if let error {
        result(FlutterError(
          code: "permission_failed",
          message: error.localizedDescription,
          details: nil
        ))
        return
      }
      guard granted else {
        result(nil)
        return
      }
      DispatchQueue.main.async {
        self.pendingPushTokenResult = result
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    UserDefaults.standard.set(token, forKey: pushTokenKey)
    pendingPushTokenResult?(token)
    pendingPushTokenResult = nil
    super.application(
      application,
      didRegisterForRemoteNotificationsWithDeviceToken: deviceToken
    )
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    pendingPushTokenResult?(FlutterError(
      code: "registration_failed",
      message: error.localizedDescription,
      details: nil
    ))
    pendingPushTokenResult = nil
    super.application(
      application,
      didFailToRegisterForRemoteNotificationsWithError: error
    )
  }
}
