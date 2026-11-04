//
//  ShareViewController.swift
//  ShareExtension
//
//  Receives shared links, text, photos and files (e.g. PDFs) on iPhone/iPad
//  and leaves them as request files in the App Group folder. THEapp imports
//  them into the Archive (AppState.importSharedItems → send_to.dart) when it
//  starts or comes back to the front; nothing is put into a note, sent to
//  AI or uploaded. No network.
//
//  Safety: items over the size limits are skipped; files are copied (the
//  originals are not touched); each request's name is a hash of its
//  content, so a share the system delivers twice is stored once.
//
//  Needs the App Group group.com.theapp.shared on this target and Runner
//  (paid Apple Developer Program). Without it nothing is saved and the
//  sheet says so. Compiled by the cloud build; not run on a device yet.
//

import CryptoKit
import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
  private let appGroupIdentifier = "group.com.theapp.shared"
  private let maxFileBytes = 100 * 1024 * 1024
  private let maxTextChars = 200_000
  private var saved = 0
  private var skipped = 0
  private let lock = NSLock()

  private let label = UILabel()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor(white: 0.1, alpha: 0.85)
    label.textColor = .white
    label.textAlignment = .center
    label.numberOfLines = 0
    label.text = "Adding to misc.…"
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
    ])
    if container == nil {
      finish(message: "misc. cannot receive shared items on this install (App Group missing).")
      return
    }
    processSharedContent()
  }

  private func count(saved ok: Bool) {
    lock.lock()
    if ok { saved += 1 } else { skipped += 1 }
    lock.unlock()
  }

  /// Every shared item becomes one request; the sheet closes once all are
  /// written.
  private func processSharedContent() {
    let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
    let group = DispatchGroup()
    for item in items {
      for provider in item.attachments ?? [] {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
          && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        {
          group.enter()
          provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) {
            [weak self] data, _ in
            defer { group.leave() }
            // Some apps hand over the link as bytes, not a URL.
            let url =
              (data as? URL)
              ?? (data as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            if let url = url, url.scheme == "http" || url.scheme == "https" {
              self?.count(saved: self?.saveRequest(type: "url", value: url.absoluteString) ?? false)
            } else {
              self?.count(saved: false)
            }
          }
        } else if provider.canLoadObject(ofClass: UIImage.self)
          && !provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
        {
          group.enter()
          provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            defer { group.leave() }
            if let image = object as? UIImage {
              self?.count(saved: self?.saveImage(image) ?? false)
            } else {
              self?.count(saved: false)
            }
          }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier)
          && !provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        {
          // Files (PDFs and others): a copy goes to the App Group.
          group.enter()
          let type =
            provider.registeredTypeIdentifiers.first {
              UTType($0)?.conforms(to: .data) ?? false
            } ?? UTType.data.identifier
          provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, _ in
            defer { group.leave() }
            if let url = url {
              self?.count(saved: self?.saveFile(url) ?? false)
            } else {
              self?.count(saved: false)
            }
          }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
          group.enter()
          provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) {
            [weak self] data, _ in
            defer { group.leave() }
            let text =
              (data as? String)
              ?? (data as? Data).flatMap { String(data: $0, encoding: .utf8) }
            if let text = text, !text.isEmpty, let self = self {
              self.count(
                saved: self.saveRequest(type: "text", value: String(text.prefix(self.maxTextChars))))
            } else {
              self?.count(saved: false)
            }
          }
        }
      }
    }
    group.notify(queue: .main) { [weak self] in
      guard let self = self else { return }
      self.finish(
        message: self.skipped == 0
          ? "Added to the misc. Archive."
          : "Added \(self.saved); \(self.skipped) could not be added (too large or not supported).")
    }
  }

  private func finish(message: String) {
    DispatchQueue.main.async {
      self.label.text = message
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
      }
    }
  }

  private var container: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
  }

  private static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(32).description
  }

  private func filesDir() throws -> URL? {
    guard let container = container else { return nil }
    let dir = container.appendingPathComponent("inbox_files", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Photos are stored as JPEG next to the requests; the app deletes the
  /// copy once it is imported ("temporary": true).
  private func saveImage(_ image: UIImage) -> Bool {
    guard let data = image.jpegData(compressionQuality: 0.9), data.count <= maxFileBytes else {
      return false
    }
    do {
      guard let dir = try filesDir() else { return false }
      let name = Self.hash(data)
      let file = dir.appendingPathComponent("\(name).jpg")
      if !FileManager.default.fileExists(atPath: file.path) {
        try data.write(to: file, options: .atomic)
      }
      return saveRequest(type: "file", value: file.path, temporary: true, id: name)
    } catch {
      NSLog("ShareExtension: could not save photo: \(error)")
      return false
    }
  }

  /// A shared file, copied (the system deletes its temporary original when
  /// this returns).
  private func saveFile(_ url: URL) -> Bool {
    do {
      let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      guard size > 0, size <= maxFileBytes, let dir = try filesDir() else { return false }
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      let name = Self.hash(data)
      let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension.lowercased()
      let file = dir.appendingPathComponent("\(name).\(ext)")
      if !FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.copyItem(at: url, to: file)
      }
      return saveRequest(type: "file", value: file.path, temporary: true, id: name)
    } catch {
      NSLog("ShareExtension: could not save file: \(error)")
      return false
    }
  }

  /// Same format as Windows "Send to" requests. Written atomically, so the
  /// app never reads half a file; named by content, so a repeat is one file.
  private func saveRequest(
    type: String, value: String, temporary: Bool = false, id: String? = nil
  ) -> Bool {
    guard let container = container else {
      NSLog("ShareExtension: App Group not available; nothing saved")
      return false
    }
    var payload: [String: Any] = [
      "type": type,
      "value": value,
      "at": ISO8601DateFormatter().string(from: Date()),
      "source": "ios_share_sheet",
    ]
    if temporary { payload["temporary"] = true }
    let dir = container.appendingPathComponent("inbox_requests", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let name = id ?? Self.hash(Data("\(type)|\(value)".utf8))
      let file = dir.appendingPathComponent("\(name).json")
      if FileManager.default.fileExists(atPath: file.path) { return true }  // delivered twice
      let data = try JSONSerialization.data(withJSONObject: payload)
      try data.write(to: file, options: .atomic)
      return true
    } catch {
      NSLog("ShareExtension: could not save request: \(error)")
      return false
    }
  }
}
