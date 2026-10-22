import Flutter
import PhotosUI
import Security
import UIKit

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
/// incoming theapp:// links, the App Group folder, opening web links, the
/// photo picker and the Keychain. No plugins, no paid services.
///
/// UNTESTED: written on Windows and never compiled or run. See
/// ios/README_IOS.md for how to check it on a Mac.
final class TheAppIosBridge: NSObject, PHPickerViewControllerDelegate {
  static let shared = TheAppIosBridge()

  /// Only usable with the paid Apple Developer Program; without it the
  /// container is nil and the app simply has no Share Extension inbox.
  static let appGroup = "group.com.theapp.shared"

  private var channel: FlutterMethodChannel?
  private var dartReady = false
  private var pendingLinks: [String] = []
  private var pickResult: FlutterResult?

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
