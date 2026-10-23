import Flutter
import PhotosUI
import QuickLook
import Security
import UIKit
import UniformTypeIdentifiers
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TheAppIosBridge") {
      TheAppIosBridge.shared.attach(messenger: registrar.messenger())
    }
  }
}

/// Native half of lib/platform/ios_bridge.dart (method channel "theapp/ios"):
/// incoming theapp:// links, the App Group folder, opening web links, task
/// reminder notifications, the photo and PDF pickers, Quick Look and the
/// Keychain. No plugins, no paid services.
///
/// UNTESTED: written on Windows and never compiled or run. See
/// ios/README_IOS.md for how to check it on a Mac.
final class TheAppIosBridge: NSObject, PHPickerViewControllerDelegate,
  UIDocumentPickerDelegate, QLPreviewControllerDataSource
{
  static let shared = TheAppIosBridge()

  /// Only usable with the paid Apple Developer Program; without it the
  /// container is nil and the app simply has no Share Extension inbox.
  static let appGroup = "group.com.theapp.shared"

  private var channel: FlutterMethodChannel?
  private var dartReady = false
  private var pendingLinks: [String] = []
  private var pickResult: FlutterResult?
  private var documentResult: FlutterResult?
  private var previewURL: URL?

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "theapp/ios", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
    self.channel = channel
  }

  /// Called by SceneDelegate. Links are held until Dart is listening, so
  /// one that launched the app is not lost.
  func received(url: URL) {
    guard url.scheme?.lowercased() == "theapp" else { return }
    if dartReady, let channel = channel {
      channel.invokeMethod("openedUrl", arguments: url.absoluteString)
    } else {
      pendingLinks.append(url.absoluteString)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "initialLinks":
      dartReady = true
      result(pendingLinks)
      pendingLinks = []
    case "sharedContainer":
      result(
        FileManager.default
          .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)?.path)
    case "openUrl":
      guard let text = call.arguments as? String, let url = URL(string: text),
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
      else {
        result(false)
        return
      }
      UIApplication.shared.open(url, options: [:]) { ok in result(ok) }
    case "deviceModel":
      result(UIDevice.current.model)
    case "appFolders":
      // HOME is not set for iOS apps, so Dart asks here for the real folders.
      let fm = FileManager.default
      var folders: [String: String] = [:]
      if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        folders["applicationSupport"] = support.path
      }
      if let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
        folders["documents"] = documents.path
      }
      result(folders)
    case "scheduleReminders":
      scheduleReminders(call.arguments as? [[String: Any]] ?? [], result)
    case "pickDocuments":
      pickDocuments(result)
    case "openDocument":
      openDocument(call.arguments as? String, result)
    case "pickImages":
      pickImages(result)
    case "keychainRead":
      result(keychainRead(call.arguments as? String ?? ""))
    case "keychainWrite":
      let args = call.arguments as? [String: String] ?? [:]
      result(keychainWrite(args["key"] ?? "", args["value"] ?? ""))
    case "keychainDelete":
      result(keychainDelete(call.arguments as? String ?? ""))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Keychain (token for the sync hub; this device only)

  private func query(_ key: String) -> [String: Any] {
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "THEapp",
      kSecAttrAccount as String: key,
    ]
  }

  private func keychainRead(_ key: String) -> String? {
    var q = query(key)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func keychainWrite(_ key: String, _ value: String) -> Bool {
    guard !key.isEmpty else { return false }
    _ = keychainDelete(key)
    var q = query(key)
    q[kSecValueData as String] = Data(value.utf8)
    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
  }

  private func keychainDelete(_ key: String) -> Bool {
    let status = SecItemDelete(query(key) as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }

  // MARK: Task reminders (local notifications; no server, free account is fine)

  private static let reminderPrefix = "theapp.reminder."

  /// Replaces all of THEapp's pending reminders with `items`
  /// ([{id, title, at (ms since 1970)}]). Permission is asked only once
  /// there is something to schedule.
  private func scheduleReminders(_ items: [[String: Any]], _ result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    center.getPendingNotificationRequests { pending in
      let old = pending.map { $0.identifier }.filter { $0.hasPrefix(Self.reminderPrefix) }
      center.removePendingNotificationRequests(withIdentifiers: old)
      guard !items.isEmpty else {
        DispatchQueue.main.async { result(true) }
        return
      }
      center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else {
          DispatchQueue.main.async { result(false) }
          return
        }
        for item in items.prefix(60) {
          guard let id = item["id"] as? String,
            let title = item["title"] as? String,
            let at = (item["at"] as? NSNumber)?.doubleValue
          else { continue }
          let seconds = Date(timeIntervalSince1970: at / 1000).timeIntervalSinceNow
          guard seconds > 1 else { continue }
          let content = UNMutableNotificationContent()
          content.title = "Reminder"
          content.body = title
          content.sound = .default
          let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
          center.add(
            UNNotificationRequest(
              identifier: Self.reminderPrefix + id, content: content, trigger: trigger))
        }
        DispatchQueue.main.async { result(true) }
      }
    }
  }

  // MARK: Photo picker (PHPicker needs no photo-library permission)

  private func pickImages(_ result: @escaping FlutterResult) {
    guard pickResult == nil, let top = topViewController() else {
      result([String]())
      return
    }
    var config = PHPickerConfiguration()
    config.filter = .images
    config.selectionLimit = 0  // any number
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    pickResult = result
    top.present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    let finish = pickResult
    pickResult = nil
    // Every photo is saved as JPEG (HEIC is not among the app's image types).
    let group = DispatchGroup()
    let lock = NSLock()
    var paths = [String?](repeating: nil, count: results.count)
    for (index, item) in results.enumerated()
    where item.itemProvider.canLoadObject(ofClass: UIImage.self) {
      group.enter()
      item.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
        defer { group.leave() }
        guard let image = object as? UIImage,
          let data = image.jpegData(compressionQuality: 0.9)
        else { return }
        let url = FileManager.default.temporaryDirectory
          .appendingPathComponent("\(UUID().uuidString).jpg")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        lock.lock()
        paths[index] = url.path
        lock.unlock()
      }
    }
    group.notify(queue: .main) { finish?(paths.compactMap { $0 }) }
  }

  // MARK: PDF documents (document picker + Quick Look; no permission needed)

  private func pickDocuments(_ result: @escaping FlutterResult) {
    guard documentResult == nil, let top = topViewController() else {
      result([String]())
      return
    }
    // asCopy: the app receives its own copies in its sandbox.
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
    picker.allowsMultipleSelection = true
    picker.delegate = self
    documentResult = result
    top.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let finish = documentResult
    documentResult = nil
    finish?(urls.map { $0.path })
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let finish = documentResult
    documentResult = nil
    finish?([String]())
  }

  /// Shows a PDF stored by the app. Only `.pdf` files inside this app's own
  /// container are accepted.
  private func openDocument(_ path: String?, _ result: @escaping FlutterResult) {
    guard let path = path, path.lowercased().hasSuffix(".pdf"),
      path.hasPrefix(NSHomeDirectory()),
      FileManager.default.fileExists(atPath: path),
      let top = topViewController()
    else {
      result(false)
      return
    }
    previewURL = URL(fileURLWithPath: path)
    let preview = QLPreviewController()
    preview.dataSource = self
    top.present(preview, animated: true)
    result(true)
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    return previewURL == nil ? 0 : 1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
    -> QLPreviewItem
  {
    return previewURL! as NSURL
  }

  private func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
