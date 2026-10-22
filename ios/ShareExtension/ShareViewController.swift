//
//  ShareViewController.swift
//  ShareExtension
//
//  Receives shared links, text and photos on iPhone/iPad and leaves them as
//  request files in the App Group folder. THEapp imports them into the Inbox
//  (lib/features/capture/send_to.dart, processRequests) when it starts or
//  comes back to the front. No network, no cloud.
//
//  UNTESTED: written on Windows, never compiled. Needs App Groups, which
//  need the paid Apple Developer Program. See ios/README_IOS.md.
//

import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    private let appGroupIdentifier = "group.com.theapp.shared"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.1, alpha: 0.8)
        processSharedContent()
    }

    /// Every shared item becomes one request; the sheet closes once all are
    /// written.
    private func processSharedContent() {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let group = DispatchGroup()
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] data, _ in
                        defer { group.leave() }
                        if let url = data as? URL, !url.isFileURL {
                            self?.saveRequest(type: "url", value: url.absoluteString)
                        }
                    }
                } else if provider.canLoadObject(ofClass: UIImage.self) {
                    group.enter()
                    provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                        defer { group.leave() }
                        if let image = object as? UIImage {
                            self?.saveImage(image)
                        }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    group.enter()
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] data, _ in
                        defer { group.leave() }
                        if let text = data as? String {
                            self?.saveRequest(type: "text", value: text)
                        }
                    }
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    private var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    /// Photos are stored as JPEG next to the requests; the app deletes the
    /// copy once it is imported ("temporary": true).
    private func saveImage(_ image: UIImage) {
        guard let container = container,
              let data = image.jpegData(compressionQuality: 0.9) else { return }
        let dir = container.appendingPathComponent("inbox_files", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(UUID().uuidString).jpg")
            try data.write(to: file, options: .atomic)
            saveRequest(type: "file", value: file.path, temporary: true)
        } catch {
            NSLog("ShareExtension: could not save photo: \(error)")
        }
    }

    /// Same format as Windows "Send to" requests. Written atomically, so the
    /// app never reads half a file.
    private func saveRequest(type: String, value: String, temporary: Bool = false) {
        guard let container = container else {
            NSLog("ShareExtension: App Group not available; nothing saved")
            return
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
            let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)
        } catch {
            NSLog("ShareExtension: could not save request: \(error)")
        }
    }
}
