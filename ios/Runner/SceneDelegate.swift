import Flutter
import UIKit
import AppIntents

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
                      options connectionOptions: UIScene.ConnectionOptions) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for context in connectionOptions.urlContexts { LaunchActions.open(context.url) }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    let remaining = URLContexts.filter { !LaunchActions.open($0.url) }
    if !remaining.isEmpty { super.scene(scene, openURLContexts: Set(remaining)) }
  }
}

/// Main-thread handoff also retains intents received before Dart is ready.
enum LaunchActions {
  static var channel: FlutterMethodChannel?
  static var ready = false
  static var pending: String?
  static func send(_ action: String) {
    if ready { channel?.invokeMethod("launch", arguments: action) }
    else { pending = action }
  }
  @discardableResult static func open(_ url: URL) -> Bool {
    guard url.scheme == "nianxia", url.path.isEmpty, url.query == nil,
          url.fragment == nil, url.user == nil, url.password == nil, url.port == nil else { return false }
    switch url.host {
    case "capture": send("capsule"); return true
    case "search": send("search"); return true
    default: return false
    }
  }
}

struct CaptureIdeaIntent: AppIntent {
  static var title: LocalizedStringResource = "记一下"
  static var description = IntentDescription("直接打开念下录音胶囊，不经过记录列表。")
  static var openAppWhenRun: Bool = true
  @MainActor func perform() async throws -> some IntentResult {
    LaunchActions.send("capsule")
    return .result()
  }
}

struct FindIdeaIntent: AppIntent {
  static var title: LocalizedStringResource = "找一下"
  static var openAppWhenRun: Bool = true
  @MainActor func perform() async throws -> some IntentResult {
    LaunchActions.send("search")
    return .result()
  }
}

struct NianxiaShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: CaptureIdeaIntent(), phrases: ["用\(.applicationName)记一下"],
                shortTitle: "记一下", systemImageName: "mic")
    AppShortcut(intent: FindIdeaIntent(), phrases: ["用\(.applicationName)找一下"],
                shortTitle: "找一下", systemImageName: "magnifyingglass")
  }
}
