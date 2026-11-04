import Flutter
import LocalAuthentication
import PDFKit
import PhotosUI
import QuickLook
import Security
import UIKit
import UniformTypeIdentifiers
import UserNotifications
import Vision
import WebKit

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
    // Safari's engine on iPhone/iPad: WKWebView as a Flutter platform view.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TheAppWebView") {
      registrar.register(
        TheAppWebViewFactory(messenger: registrar.messenger()), withId: "theapp/webview")
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
  UIDocumentPickerDelegate, QLPreviewControllerDataSource, UIPencilInteractionDelegate
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
  private var pencilInteraction: UIPencilInteraction?
  private let peers = PeerBonjour()

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "theapp/ios", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
    self.channel = channel
    // Tell Dart when protected (NSFileProtectionComplete) files become
    // readable or unreadable, so writes wait instead of being weakened.
    let center = NotificationCenter.default
    center.addObserver(
      forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.channel?.invokeMethod("protectedData", arguments: true) }
    center.addObserver(
      forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil,
      queue: .main
    ) { [weak self] _ in self?.channel?.invokeMethod("protectedData", arguments: false) }
  }

  /// Called by SceneDelegate. Links are held until Dart is listening, so
  /// one that launched the app is not lost.
  func received(url: URL) {
    // theapp:// links, and calendar sign-in redirects (Microsoft's
    // msauth.<bundle id> scheme, Google's reversed client id scheme).
    let scheme = url.scheme?.lowercased() ?? ""
    guard
      scheme == "theapp" || scheme.hasPrefix("msauth.")
        || scheme.hasPrefix("com.googleusercontent.apps.")
    else { return }
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
    case "pdfInfo":
      pdfInfo(call.arguments as? String, result)
    case "pdfRenderPage":
      pdfRenderPage(call.arguments as? [String: Any] ?? [:], result)
    case "ocrPdf":
      ocrPdf(call.arguments as? [String: Any] ?? [:], result)
    case "ocrImage":
      ocrImage(call.arguments as? String, result)
    case "pdfExport":
      pdfExport(call.arguments as? [String: Any] ?? [:], result)
    case "shareFile":
      shareFile(call.arguments as? String, result)
    case "widgetSnapshot":
      result(writeWidgetSnapshot(call.arguments as? String))
    case "enablePencilSqueeze":
      result(installPencilInteraction())
    case "deviceModel":
      result(UIDevice.current.model)
    case "peerAdvertise":
      let args = call.arguments as? [String: Any] ?? [:]
      peers.advertise(
        name: args["name"] as? String ?? "misc",
        port: Int32(args["port"] as? Int ?? 0),
        txt: args["txt"] as? [String: String] ?? [:])
      result(nil)
    case "peerBrowse":
      peers.onFound = { [weak self] info in self?.channel?.invokeMethod("peerFound", arguments: info) }
      peers.onLost = { [weak self] name in self?.channel?.invokeMethod("peerLost", arguments: name) }
      peers.browse()
      result(nil)
    case "peerStop":
      peers.stop()
      result(nil)
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
      pickDocuments(call.arguments as? String, result)
    case "openDocument":
      openDocument(call.arguments as? String, result)
    case "pickImages":
      pickImages(result)
    case "protectedDataAvailable":
      result(UIApplication.shared.isProtectedDataAvailable)
    case "protectPaths":
      result(Self.protect(call.arguments as? [String] ?? [], recursive: false))
    case "protectTree":
      result(Self.protect(call.arguments as? [String] ?? [], recursive: true))
    case "biometricAvailable":
      result(LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil))
    case "biometricAuthenticate":
      biometricAuthenticate(call.arguments as? String ?? "Unlock misc.", result)
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

  // MARK: Biometric app lock (Face ID / Touch ID only; never the passcode)

  private func biometricAuthenticate(_ reason: String, _ result: @escaping FlutterResult) {
    let context = LAContext()
    context.localizedFallbackTitle = ""  // hides "Enter Passcode"
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
      result("unavailable")
      return
    }
    context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) {
      ok, error in
      DispatchQueue.main.async {
        if ok {
          result("success")
          return
        }
        switch (error as? LAError)?.code {
        case .some(.userCancel), .some(.appCancel), .some(.systemCancel), .some(.userFallback):
          result("cancelled")
        case .some(.biometryNotAvailable), .some(.biometryNotEnrolled), .some(.biometryLockout):
          result("unavailable")
        default:
          result("failed")
        }
      }
    }
  }

  // MARK: File protection (NSFileProtectionComplete)

  /// Marks each path (and, when `recursive`, everything below it) complete-
  /// protected. False if any item failed, e.g. the device is locked or the
  /// path is missing; Dart then retries after unlock.
  static func protect(_ paths: [String], recursive: Bool) -> Bool {
    let fm = FileManager.default
    var ok = true
    func apply(_ path: String) {
      do {
        try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: path)
      } catch {
        ok = false
      }
    }
    for path in paths {
      guard fm.fileExists(atPath: path) else {
        ok = false
        continue
      }
      apply(path)
      if recursive, let items = fm.enumerator(atPath: path) {
        for case let relative as String in items {
          apply((path as NSString).appendingPathComponent(relative))
        }
      }
    }
    return ok
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

  // MARK: PDFs in notes (PDFKit, part of iOS; the original file is never changed)

  /// Page sizes in points, after each page's rotation.
  private func pdfInfo(_ path: String?, _ result: @escaping FlutterResult) {
    guard let path = path, let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
      result(nil)
      return
    }
    var sizes: [[Double]] = []
    for i in 0..<doc.pageCount {
      guard let page = doc.page(at: i) else { continue }
      let box = page.bounds(for: .cropBox)
      let turned = page.rotation % 180 != 0
      sizes.append(
        turned
          ? [Double(box.height), Double(box.width)] : [Double(box.width), Double(box.height)])
    }
    result(sizes)
  }

  /// On-device text recognition (Vision) for scanned PDFs, page by page,
  /// off the main thread. Pages are rendered at most 2000 px on their long
  /// side; nothing leaves the device.
  private func ocrPdf(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard let path = args["path"] as? String else {
      result(nil)
      return
    }
    let maxPages = min(args["maxPages"] as? Int ?? 50, 200)
    DispatchQueue.global(qos: .utility).async {
      var pages: [String] = []
      if let doc = PDFDocument(url: URL(fileURLWithPath: path)) {
        for i in 0..<min(doc.pageCount, maxPages) {
          autoreleasepool {
            guard let page = doc.page(at: i) else {
              pages.append("")
              return
            }
            let box = page.bounds(for: .mediaBox)
            let longest = max(box.width, box.height)
            let scale = longest > 0 ? min(3.0, 2000.0 / longest) : 1.0
            let image = page.thumbnail(
              of: CGSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
            guard let cg = image.cgImage else {
              pages.append("")
              return
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            pages.append(lines.joined(separator: "\n"))
          }
        }
      }
      DispatchQueue.main.async { result(pages) }
    }
  }

  /// On-device Vision recognition for a temporary calendar handwriting image.
  /// No image data or recognized text leaves the device.
  private func ocrImage(_ path: String?, _ result: @escaping FlutterResult) {
    guard let path = path else {
      result(FlutterError(code: "ocr_image", message: "Missing image path", details: nil))
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let url = URL(fileURLWithPath: path)
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      do {
        try VNImageRequestHandler(url: url, options: [:]).perform([request])
        let lines = (request.results ?? [])
          .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
          .compactMap { $0.topCandidates(1).first?.string }
        DispatchQueue.main.async { result(lines.joined(separator: "\n")) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "ocr_image", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  /// One page as PNG, [width] pixels wide, rendered off the main thread so
  /// long PDFs load page by page as they scroll into view.
  private func pdfRenderPage(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard let path = args["path"] as? String, let index = args["page"] as? Int,
      let width = args["width"] as? Int, width > 0, width <= 4096
    else {
      result(nil)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      var data: Data?
      if let doc = PDFDocument(url: URL(fileURLWithPath: path)), let page = doc.page(at: index) {
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let w = turned ? box.height : box.width
        let h = turned ? box.width : box.height
        if w > 0 {
          let size = CGSize(width: CGFloat(width), height: CGFloat(width) * h / w)
          data = page.thumbnail(of: size, for: .cropBox).pngData()
        }
      }
      DispatchQueue.main.async {
        result(data.map { FlutterStandardTypedData(bytes: $0) })
      }
    }
  }

  /// Writes a copy of the PDF with the note's ink drawn on its pages.
  /// Strokes come in PDF points from the top-left: [[x, y, width], …].
  private func pdfExport(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard let source = args["source"] as? String, let target = args["target"] as? String,
      let doc = PDFDocument(url: URL(fileURLWithPath: source))
    else {
      result(false)
      return
    }
    var ink: [Int: [[String: Any]]] = [:]
    for page in args["pages"] as? [[String: Any]] ?? [] {
      if let index = page["page"] as? Int {
        ink[index] = page["strokes"] as? [[String: Any]] ?? []
      }
    }
    let renderer = UIGraphicsPDFRenderer(bounds: .zero)
    do {
      try renderer.writePDF(to: URL(fileURLWithPath: target)) { ctx in
        for i in 0..<doc.pageCount {
          guard let page = doc.page(at: i) else { continue }
          let box = page.bounds(for: .cropBox)
          let turned = page.rotation % 180 != 0
          let size = turned ? CGSize(width: box.height, height: box.width) : box.size
          ctx.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
          let cg = ctx.cgContext
          cg.saveGState()
          // PDF space has its origin at the bottom left.
          cg.translateBy(x: 0, y: size.height)
          cg.scaleBy(x: 1, y: -1)
          page.draw(with: .cropBox, to: cg)
          cg.restoreGState()
          for stroke in ink[i] ?? [] {
            Self.drawStroke(stroke, in: cg)
          }
        }
      }
      _ = Self.protect([target], recursive: false)
      result(true)
    } catch {
      NSLog("misc.: PDF export failed: \(error)")
      result(false)
    }
  }

  private static func drawStroke(_ stroke: [String: Any], in cg: CGContext) {
    guard let points = stroke["points"] as? [[Double]], let first = points.first,
      first.count >= 3
    else { return }
    let argb = (stroke["color"] as? NSNumber)?.uint32Value ?? 0xFF00_0000
    let color = UIColor(
      red: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255, alpha: CGFloat((argb >> 24) & 0xFF) / 255)
    cg.setStrokeColor(color.cgColor)
    cg.setFillColor(color.cgColor)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    if points.count == 1 {
      let r = first[2] / 2
      cg.fillEllipse(in: CGRect(x: first[0] - r, y: first[1] - r, width: r * 2, height: r * 2))
      return
    }
    for i in 1..<points.count {
      let a = points[i - 1]
      let b = points[i]
      guard a.count >= 3, b.count >= 3 else { continue }
      cg.setLineWidth(CGFloat((a[2] + b[2]) / 2))
      cg.move(to: CGPoint(x: a[0], y: a[1]))
      cg.addLine(to: CGPoint(x: b[0], y: b[1]))
      cg.strokePath()
    }
  }

  /// Share sheet for a file (Save to Files, AirDrop, Mail…).
  private func shareFile(_ path: String?, _ result: @escaping FlutterResult) {
    guard let path = path, FileManager.default.fileExists(atPath: path),
      let top = topViewController()
    else {
      result(false)
      return
    }
    let sheet = UIActivityViewController(
      activityItems: [URL(fileURLWithPath: path)], applicationActivities: nil)
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = top.view
      popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
      popover.permittedArrowDirections = []
    }
    top.present(sheet, animated: true)
    result(true)
  }

  // MARK: Apple Pencil Pro squeeze (iOS 17.5+; other Pencils never send it)

  /// Adds one UIPencilInteraction to the app window so squeezes reach
  /// THEapp. Returns false if there is no window yet.
  private func installPencilInteraction() -> Bool {
    if pencilInteraction != nil { return true }
    guard let view = topViewController()?.view.window ?? topViewController()?.view
    else { return false }
    let interaction = UIPencilInteraction()
    interaction.delegate = self
    view.addInteraction(interaction)
    pencilInteraction = interaction
    return true
  }

  /// Squeeze phases: began (eraser on), changed (ignored), ended or
  /// cancelled (previous tool back). Sent to Dart as "pencilSqueeze".
  @available(iOS 17.5, *)
  func pencilInteraction(
    _ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
  ) {
    let phase: String
    switch squeeze.phase {
    case .began: phase = "began"
    case .changed: return
    case .ended: phase = "ended"
    case .cancelled: phase = "cancelled"
    @unknown default: phase = "cancelled"
    }
    channel?.invokeMethod("pencilSqueeze", arguments: phase)
  }

  // MARK: Apple Pencil double-tap (2nd generation and Pro): THEapp's Undo

  private var lastPencilTap: TimeInterval = 0

  /// The double-tap action chosen in iPadOS Settings → Apple Pencil, as
  /// Dart sees it: "ignore" means the user turned double-tap off, and
  /// THEapp then does nothing.
  private func preferredPencilTapAction() -> String {
    switch UIPencilInteraction.preferredTapAction {
    case .ignore: return "ignore"
    case .switchEraser: return "switchEraser"
    case .switchPrevious: return "switchPrevious"
    case .showColorPalette: return "showColorPalette"
    default: return "other"
    }
  }

  /// One tap reaches Dart once, whichever API delivered it (both exist so
  /// the tap works before and after iPadOS 17.5).
  private func sendPencilTap() {
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastPencilTap < 0.25 { return }
    lastPencilTap = now
    channel?.invokeMethod("pencilDoubleTap", arguments: preferredPencilTapAction())
  }

  /// Before iPadOS 17.5.
  func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
    sendPencilTap()
  }

  /// iPadOS 17.5 and later (only the end of a tap is used).
  @available(iOS 17.5, *)
  func pencilInteraction(
    _ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap
  ) {
    sendPencilTap()
  }

  // MARK: Task reminders (local notifications; no server, free account is fine)

  private static let reminderPrefix = "theapp.reminder."

  /// Replaces all of THEapp's pending reminders with `items`
  /// ([{id, title, at (ms since 1970)}]). Permission is asked only once
  /// there is something to schedule.
  // MARK: home-screen widgets

  /// The widgets (TheAppWidget extension) read this file. It is derived,
  /// display-only data; false when there is no App Group to share it in.
  private func writeWidgetSnapshot(_ json: String?) -> Bool {
    guard let data = json?.data(using: .utf8),
      let folder = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: Self.appGroup)
    else { return false }
    do {
      try data.write(
        to: folder.appendingPathComponent("widget_snapshot.json"), options: .atomic)
    } catch {
      return false
    }
    WidgetReload.all()
    return true
  }

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
        guard (try? data.write(to: url, options: [.atomic, .completeFileProtection])) != nil else { return }
        lock.lock()
        paths[index] = url.path
        lock.unlock()
      }
    }
    group.notify(queue: .main) { finish?(paths.compactMap { $0 }) }
  }

  // MARK: PDF documents (document picker + Quick Look; no permission needed)

  /// [kind] "backup": a THEapp backup file (any file type is offered, the
  /// app checks the contents); otherwise PDFs.
  private func pickDocuments(_ kind: String?, _ result: @escaping FlutterResult) {
    guard documentResult == nil, let top = topViewController() else {
      result([String]())
      return
    }
    // asCopy: the app receives its own copies in its sandbox.
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: kind == "backup" ? [.data] : [.pdf], asCopy: true)
    picker.allowsMultipleSelection = kind != "backup"
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

// MARK: - Safari engine (WKWebView platform view)

/// Native half of lib/features/browser/browser_engine.dart (WebKitEngine).
/// Each view has its own channel "theapp/webview/<id>". Private tabs use a
/// non-persistent data store. UNTESTED on a device: compiled only by the
/// cloud build.
final class TheAppWebViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?)
    -> FlutterPlatformView
  {
    let isPrivate = (args as? [String: Any])?["private"] as? Bool ?? false
    return TheAppWebView(frame: frame, viewId: viewId, messenger: messenger, isPrivate: isPrivate)
  }
}

final class TheAppWebView: NSObject, FlutterPlatformView, WKNavigationDelegate, WKUIDelegate,
  WKDownloadDelegate
{
  private let webView: WKWebView
  private let channel: FlutterMethodChannel
  private var observations: [NSKeyValueObservation] = []
  private var lastError: String?
  private var downloads: [ObjectIdentifier: (id: String, url: String, name: String, path: URL?)] =
    [:]

  init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger, isPrivate: Bool) {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = isPrivate ? .nonPersistent() : .default()
    config.allowsInlineMediaPlayback = true
    webView = WKWebView(frame: frame, configuration: config)
    webView.allowsBackForwardNavigationGestures = true
    channel = FlutterMethodChannel(name: "theapp/webview/\(viewId)", binaryMessenger: messenger)
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    if #available(iOS 16.0, *) { webView.isFindInteractionEnabled = true }
    observations = [
      webView.observe(\.url) { [weak self] _, _ in self?.sendState() },
      webView.observe(\.title) { [weak self] _, _ in self?.sendState() },
      webView.observe(\.isLoading) { [weak self] _, _ in self?.sendState() },
      webView.observe(\.estimatedProgress) { [weak self] _, _ in self?.sendState() },
      webView.observe(\.canGoBack) { [weak self] _, _ in self?.sendState() },
      webView.observe(\.canGoForward) { [weak self] _, _ in self?.sendState() },
    ]
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
  }

  func view() -> UIView { webView }

  private func sendState() {
    var state: [String: Any] = [
      "url": webView.url?.absoluteString ?? "",
      "title": webView.title ?? "",
      "loading": webView.isLoading,
      "progress": webView.estimatedProgress,
      "canGoBack": webView.canGoBack,
      "canGoForward": webView.canGoForward,
    ]
    if let error = lastError { state["error"] = error }
    channel.invokeMethod("state", arguments: state)
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "load":
      guard let text = call.arguments as? String, let url = URL(string: text),
        url.scheme == "http" || url.scheme == "https"
      else {
        result(FlutterError(code: "bad_url", message: "Only web addresses can be opened", details: nil))
        return
      }
      lastError = nil
      webView.load(URLRequest(url: url))
      result(nil)
    case "back": webView.goBack(); result(nil)
    case "forward": webView.goForward(); result(nil)
    case "reload": lastError = nil; webView.reload(); result(nil)
    case "stop": webView.stopLoading(); result(nil)
    case "zoom":
      if let factor = call.arguments as? Double {
        webView.pageZoom = CGFloat(factor)  // iOS 14+; the app needs iOS 15
      }
      result(nil)
    case "find":
      if #available(iOS 16.0, *) {
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
      }
      result(nil)
    case "evaluate":
      // Only the two fixed read-only scripts the app sends (selection and
      // visible text); never code from a web page.
      guard let script = call.arguments as? String,
        script == "window.getSelection().toString()" || script == "document.body.innerText"
      else {
        result(nil)
        return
      }
      webView.evaluateJavaScript(script) { value, _ in result(value as? String ?? "") }
    case "clearData":
      let store = webView.configuration.websiteDataStore
      store.removeData(
        ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
      ) { result(nil) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // Navigation: only web pages load here; other schemes go to the app,
  // which asks the user (mailto:, tel:, app links). Certificate errors are
  // never bypassed.
  func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
      decisionHandler(.cancel)
      return
    }
    if ["http", "https", "about", "blob", "data"].contains(scheme) {
      if action.shouldPerformDownload {
        decisionHandler(.download)
      } else {
        decisionHandler(.allow)
      }
    } else {
      decisionHandler(.cancel)
      if scheme != "javascript" && scheme != "file" {
        channel.invokeMethod("external", arguments: url.absoluteString)
      }
    }
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
    decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
  ) {
    decisionHandler(response.canShowMIMEType ? .allow : .download)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError error: Error) {
    report(error)
  }

  func webView(_ webView: WKWebView, didFail nav: WKNavigation!, withError error: Error) {
    report(error)
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation nav: WKNavigation!) {
    lastError = nil
    sendState()
  }

  private func report(_ error: Error) {
    let ns = error as NSError
    if ns.code == NSURLErrorCancelled { return }
    let certificate = [
      NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
      NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
      NSURLErrorSecureConnectionFailed,
    ].contains(ns.code)
    lastError =
      certificate
      ? "This site's secure connection could not be verified, so it was not opened."
      : "The page could not be opened: \(ns.localizedDescription)"
    sendState()
  }

  // Pop-ups and target=_blank open as a new THEapp tab.
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for action: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = action.request.url?.absoluteString {
      channel.invokeMethod("newWindow", arguments: url)
    }
    return nil
  }

  // Camera / microphone: the app asks the user (and remembers per site).
  @available(iOS 15.0, *)
  func webView(
    _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
    decisionHandler: @escaping (WKPermissionDecision) -> Void
  ) {
    let kind: String
    switch type {
    case .camera: kind = "camera"
    case .microphone: kind = "microphone"
    default: kind = "camera and microphone"
    }
    channel.invokeMethod("permission", arguments: ["host": origin.host, "kind": kind]) { answer in
      decisionHandler((answer as? Bool) == true ? .grant : .deny)
    }
  }

  // Downloads (iOS 14.5+): saved in Documents/THEapp Downloads.
  func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
    download.delegate = self
  }

  func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
    download.delegate = self
  }

  func download(
    _ download: WKDownload, decideDestinationUsing response: URLResponse,
    suggestedFilename: String, completionHandler: @escaping (URL?) -> Void
  ) {
    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("THEapp Downloads", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let safe = (suggestedFilename as NSString).lastPathComponent
    var target = folder.appendingPathComponent(safe.isEmpty ? "download" : safe)
    var n = 2
    while FileManager.default.fileExists(atPath: target.path) {
      let base = (safe as NSString).deletingPathExtension
      let ext = (safe as NSString).pathExtension
      target = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
      n += 1
    }
    let id = UUID().uuidString
    downloads[ObjectIdentifier(download)] = (
      id: id, url: response.url?.absoluteString ?? "", name: target.lastPathComponent,
      path: Optional(target))
    observations.append(
      download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
        DispatchQueue.main.async { self?.sendDownload(download, progress: progress.fractionCompleted) }
      })
    _ = TheAppIosBridge.protect([folder.path], recursive: false)
    completionHandler(target)
    sendDownload(download, progress: 0)
  }

  func downloadDidFinish(_ download: WKDownload) {
    sendDownload(download, progress: 1, done: true)
  }

  func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
    sendDownload(download, progress: 0, error: error.localizedDescription)
  }

  private func sendDownload(_ download: WKDownload, progress: Double, done: Bool = false, error: String? = nil) {
    guard let d = downloads[ObjectIdentifier(download)] else { return }
    var args: [String: Any] = [
      "id": d.id, "url": d.url, "fileName": d.name, "progress": progress, "done": done,
    ]
    if done, let path = d.path?.path { args["path"] = path }
    if let error = error { args["error"] = error }
    channel.invokeMethod("download", arguments: args)
  }
}

// MARK: Direct device sync: Bonjour on the local network
//
// Announces this device as `_misc-sync._tcp` (the port is the one the app's
// own peer hub listens on) and looks for the same service from other devices.
// The TXT record carries only the device id and the public workspace tag; no
// key and no data. Needs NSLocalNetworkUsageDescription and
// NSBonjourServices in Info.plist (no paid developer account, no extra
// entitlement). Compiled only in the cloud so far; never run on a device.
final class PeerBonjour: NSObject, NetServiceDelegate, NetServiceBrowserDelegate {
  static let serviceType = "_misc-sync._tcp."
  private var service: NetService?
  private var browser: NetServiceBrowser?
  private var resolving: [String: NetService] = [:]
  var onFound: (([String: Any]) -> Void)?
  var onLost: ((String) -> Void)?

  func advertise(name: String, port: Int32, txt: [String: String]) {
    service?.stop()
    guard port > 0 else { return }
    let s = NetService(domain: "", type: Self.serviceType, name: name, port: port)
    s.setTXTRecord(NetService.data(fromTXTRecord: txt.mapValues { Data($0.utf8) }))
    s.delegate = self
    s.publish()
    service = s
  }

  func browse() {
    browser?.stop()
    let b = NetServiceBrowser()
    b.delegate = self
    b.searchForServices(ofType: Self.serviceType, inDomain: "local.")
    browser = b
  }

  func stop() {
    service?.stop()
    service = nil
    browser?.stop()
    browser = nil
    resolving.removeAll()
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didFind svc: NetService, moreComing: Bool) {
    resolving[svc.name] = svc
    svc.delegate = self
    svc.resolve(withTimeout: 5)
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didRemove svc: NetService, moreComing: Bool) {
    resolving.removeValue(forKey: svc.name)
    onLost?(svc.name)
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    var txt: [String: String] = [:]
    if let data = sender.txtRecordData() {
      for (key, value) in NetService.dictionary(fromTXTRecord: data) {
        txt[key] = String(data: value, encoding: .utf8) ?? ""
      }
    }
    var ip = ""
    for data in sender.addresses ?? [] {
      data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        let sa = base.assumingMemoryBound(to: sockaddr.self)
        if sa.pointee.sa_family == sa_family_t(AF_INET) {
          var addr = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
          var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
          inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
          ip = String(cString: buffer)
        }
      }
      if !ip.isEmpty { break }
    }
    onFound?(["name": sender.name, "host": ip, "port": sender.port, "txt": txt])
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    resolving.removeValue(forKey: sender.name)
  }
}
