import Flutter
import UIKit
import EventKit
import EventKitUI

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, EKEventEditViewDelegate {
  private var pendingCalendar: FlutterResult?
  private var eventStore: EKEventStore?
  private var appearanceChannel: FlutterMethodChannel?
  private var appearanceObservers: [NSObjectProtocol] = []

  private func appearanceSnapshot() -> [String: Bool] {
    return ["reduceMotion": UIAccessibility.isReduceMotionEnabled,
            "reduceTransparency": UIAccessibility.isReduceTransparencyEnabled,
            "increaseContrast": UIAccessibility.isDarkerSystemColorsEnabled,
            // No full iOS26 SDK/device prototype has passed the glass gate.
            "glassSupported": false]
  }

  private func configureAppearance(_ messenger: FlutterBinaryMessenger) {
    appearanceObservers.forEach { NotificationCenter.default.removeObserver($0) }
    appearanceObservers.removeAll()
    appearanceChannel?.setMethodCallHandler(nil)
    let channel = FlutterMethodChannel(name: "app.nianxia/appearance", binaryMessenger: messenger)
    appearanceChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      if call.method == "current" { result(self.appearanceSnapshot()) }
      else { result(FlutterMethodNotImplemented) }
    }
    let names: [Notification.Name] = [UIAccessibility.reduceMotionStatusDidChangeNotification,
      UIAccessibility.reduceTransparencyStatusDidChangeNotification,
      UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
      UIApplication.didBecomeActiveNotification]
    for name in names {
      appearanceObservers.append(NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main) { [weak self] _ in
          guard let self = self else { return }
          self.appearanceChannel?.invokeMethod("changed", arguments: self.appearanceSnapshot())
        })
    }
  }

  deinit {
    appearanceObservers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NianxiaSystem") else { return }
    configureAppearance(registrar.messenger())
    let channel = FlutterMethodChannel(name: "app.nianxia/system", binaryMessenger: registrar.messenger())
    LaunchActions.channel = channel
    LaunchActions.ready = false
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "validationIdentity":
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
          result(FlutterError(code: "validation_cache", message: "Private cache unavailable", details: nil)); return
        }
        let cache = cacheURL.resolvingSymlinksInPath().path
        result(["applicationId": Bundle.main.bundleIdentifier ?? "", "cacheRoot": cache,
                "temporaryRoots": [temporary, cache]])
      case "getLaunchAction":
        LaunchActions.channel = channel
        LaunchActions.ready = true
        result(LaunchActions.pending)
        LaunchActions.pending = nil
      case "dismissCapsule":
        // iOS has no public API to return to an arbitrary previous app.
        // Flutter switches to the notebook; no private suspension API is used.
        result(nil)
      case "protectFiles":
        guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
          result(FlutterError(code: "invalid_path", message: "Missing private path", details: nil)); return
        }
        do {
          var url = URL(fileURLWithPath: path, isDirectory: true)
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          try url.setResourceValues(values)
          guard try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
            throw NSError(domain: "NianxiaPrivacy", code: 1)
          }
          result(true)
        } catch {
          result(FlutterError(code: "backup_exclusion", message: "Could not exclude private files from backup", details: nil))
        }
      case "availableStorageBytes":
        do {
          let attributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
          guard let bytes = attributes[.systemFreeSize] as? NSNumber else {
            throw NSError(domain: "NianxiaStorage", code: 1)
          }
          result(bytes.int64Value)
        } catch {
          result(FlutterError(code: "storage_space", message: "Unable to inspect private storage", details: nil))
        }
      case "calendar": self.openCalendar(call.arguments, result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func openCalendar(_ arguments: Any?, result: @escaping FlutterResult) {
    guard pendingCalendar == nil else { result("unknown"); return }
    guard let args = arguments as? [String: Any], let title = args["title"] as? String,
      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200,
      let start = args["start"] as? NSNumber, let end = args["end"] as? NSNumber,
      end.doubleValue > start.doubleValue else {
      result(FlutterError(code: "invalid_event", message: "Invalid event fields", details: nil)); return
    }
    // iOS 17+ allows the system editor without reading calendars or requesting
    // full calendar access. No automatic eventStore.save() path exists.
    guard #available(iOS 17.0, *) else { result("unavailable"); return }
    guard var presenter = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
      .flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController else {
      result("unavailable"); return
    }
    while let next = presenter.presentedViewController { presenter = next }
    guard presenter.viewIfLoaded?.window != nil else { result("unavailable"); return }
    let store = EKEventStore()
    let event = EKEvent(eventStore: store)
    event.title = title
    event.location = args["location"] as? String
    event.startDate = Date(timeIntervalSince1970: start.doubleValue / 1000)
    event.endDate = Date(timeIntervalSince1970: end.doubleValue / 1000)
    if let minutes = args["reminderMinutes"] as? NSNumber, minutes.intValue >= 0, minutes.intValue <= 10080 {
      event.addAlarm(EKAlarm(relativeOffset: -minutes.doubleValue * 60))
    }
    let editor = EKEventEditViewController()
    editor.eventStore = store
    editor.event = event
    editor.editViewDelegate = self
    editor.isModalInPresentation = true
    pendingCalendar = result
    eventStore = store
    presenter.present(editor, animated: !UIAccessibility.isReduceMotionEnabled)
  }

  func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
    let result = pendingCalendar
    pendingCalendar = nil
    controller.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in
      self?.eventStore = nil
      switch action {
      case .saved: result?("saved")
      case .canceled, .deleted: result?("cancelled")
      @unknown default: result?("unknown")
      }
    }
  }
}
