import CryptoKit
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct ArchiveTag: Decodable, Identifiable, Hashable {
  let id: String
  let name: String
  let color: UInt32
}

private struct ShareDraft: Identifiable {
  let id: String
  let kind: String
  let title: String
  let value: String
  let filename: String?
  let typeIdentifier: String?
  let temporary: Bool
  let preview: String
  let thumbnail: UIImage?
}

private final class ShareModel: ObservableObject {
  @Published var drafts: [ShareDraft] = []
  @Published var tags: [ArchiveTag] = []
  @Published var selectedTag: String?
  @Published var loading = true
  @Published var saving = false
  @Published var message: String?
  @Published var error: String?
  @Published var rotationMessage = ""
  @Published var unsupportedCount = 0
}

final class ShareViewController: UIViewController {
  private let model = ShareModel()
  private let maxFileBytes: Int64 = 300 * 1024 * 1024
  private let maxTextChars = 200_000

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    let host = UIHostingController(rootView: SharePopup(model: model, onSave: { [weak self] in
      self?.save()
    }))
    addChild(host)
    host.view.backgroundColor = .clear
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)
    guard let container = AppGroup.container else {
      model.loading = false
      model.error = "THEapp cannot access shared storage on this installation. Nothing was saved."
      return
    }
    loadTagCatalog(from: container)
    loadRotatingMessage(from: container)
    collectSharedContent()
  }

  private func loadTagCatalog(from container: URL) {
    let url = container.appendingPathComponent("archive_share_tags.json")
    guard let data = try? Data(contentsOf: url),
      let tags = try? JSONDecoder().decode([ArchiveTag].self, from: data), !tags.isEmpty
    else {
      model.error = "Archive tags are unavailable. Open THEapp once to refresh them; nothing was saved."
      return
    }
    model.tags = tags
  }

  // Message files are intentionally user supplied. An empty file/list hides
  // this slot; no product copy is invented here.
  private func loadRotatingMessage(from container: URL) {
    let catalog = container.appendingPathComponent("share_messages.json")
    let configured = Bundle.main.object(forInfoDictionaryKey: "THEappShareMessages") as? [String] ?? []
    let messages: [String]
    if let data = try? Data(contentsOf: catalog),
      let shared = try? JSONDecoder().decode([String].self, from: data), !shared.isEmpty {
      messages = shared
    } else {
      messages = configured
    }
    guard !messages.isEmpty else { return }
    let stateFile = container.appendingPathComponent("share_message_state.json")
    let previous = (try? Data(contentsOf: stateFile))
      .flatMap { try? JSONDecoder().decode(Int.self, from: $0) } ?? -1
    let next = (previous + 1) % messages.count
    model.rotationMessage = messages[next]
    if let state = try? JSONEncoder().encode(next) {
      try? state.write(to: stateFile, options: .atomic)
    }
  }

  private func collectSharedContent() {
    let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
    let providers = items
      .flatMap { item in (item.attachments ?? []).map { (item, $0) } }
    let standaloneText = items.compactMap { $0.attributedContentText?.string }
    guard !providers.isEmpty || !standaloneText.isEmpty else {
      model.loading = false
      model.error = "The selected app did not provide content THEapp can save."
      return
    }
    let group = DispatchGroup()
    let lock = NSLock()
    var results: [ShareDraft] = []
    var failures: [String] = []
    for (item, provider) in providers {
      group.enter()
      load(provider: provider, webpageTitle: item.attributedTitle?.string ?? item.userInfo?["title"] as? String) { result in
        lock.lock()
        if let result { results.append(result) }
        else { failures.append("One attachment could not be read from its source app.") }
        lock.unlock()
        group.leave()
      }
    }
    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      if providers.isEmpty {
        results.append(contentsOf: standaloneText.compactMap { text in
          let clipped = String(text.prefix(self.maxTextChars))
          guard !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
          return ShareDraft(id: Self.hash(Data(clipped.utf8)), kind: "text", title: "Shared text", value: clipped, filename: nil, typeIdentifier: UTType.plainText.identifier, temporary: false, preview: clipped, thumbnail: nil)
        })
      }
      self.model.drafts = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        .values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
      self.model.loading = false
      self.model.unsupportedCount = failures.count
      if !failures.isEmpty {
        self.model.error = failures.joined(separator: " ")
      }
      if results.isEmpty && failures.isEmpty {
        self.model.error = "This item has no supported share representation. Nothing was saved."
      }
    }
  }

  private func load(provider: NSItemProvider, webpageTitle: String?, completion: @escaping (ShareDraft?) -> Void) {
    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
      && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] value, _ in
        let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
          ?? (value as? String).flatMap(URL.init(string:))
        guard let self, let url,
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host, !host.isEmpty
        else {
          completion(nil)
          return
        }
        let title = webpageTitle.flatMap { $0.isEmpty ? nil : $0 } ?? host
        completion(
          ShareDraft(
            id: Self.hash(Data(url.absoluteString.utf8)),
            kind: "url",
            title: title,
            value: url.absoluteString,
            filename: nil,
            typeIdentifier: UTType.url.identifier,
            temporary: false,
            preview: url.absoluteString,
            thumbnail: nil
          )
        )
      }
      return
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] value, _ in
        guard let self else { completion(nil); return }
        let text = (value as? String) ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { completion(nil); return }
        let clipped = String(text.prefix(self.maxTextChars))
        let normalized = clipped.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: normalized), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host {
          completion(ShareDraft(id: Self.hash(Data(url.absoluteString.utf8)), kind: "url", title: webpageTitle ?? host, value: url.absoluteString, filename: nil, typeIdentifier: UTType.url.identifier, temporary: false, preview: url.absoluteString, thumbnail: nil))
        } else {
          completion(ShareDraft(id: Self.hash(Data(clipped.utf8)), kind: "text", title: webpageTitle ?? "Shared text", value: clipped, filename: nil, typeIdentifier: UTType.plainText.identifier, temporary: false, preview: clipped, thumbnail: nil))
        }
      }
      return
    }
    let identifiers = provider.registeredTypeIdentifiers
    guard let identifier = identifiers.first(where: { id in
      guard let type = UTType(id) else { return false }
      return type.conforms(to: .fileURL) || type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf)
        || type.conforms(to: .audio) || type.conforms(to: .text) || type.conforms(to: .data)
        || type.conforms(to: .content)
    }) else { completion(nil); return }
    provider.loadFileRepresentation(forTypeIdentifier: identifier) { [weak self] source, _ in
      guard let self else { completion(nil); return }
      guard let source else {
        self.loadImageFallback(provider, webpageTitle: webpageTitle, completion: completion)
        return
      }
      do {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .nameKey, .typeIdentifierKey])
        guard let size = values.fileSize, size > 0, Int64(size) <= self.maxFileBytes,
          let folder = self.filesFolder() else { completion(nil); return }
        let ext = source.pathExtension.isEmpty
          ? (UTType(identifier)?.preferredFilenameExtension ?? "bin")
          : source.pathExtension
        let supportedExtensions: Set<String> = [
          "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "rtf", "txt", "md", "csv",
          "epub", "pages", "numbers", "key", "zip", "mov", "mp4", "m4v", "avi", "mkv",
          "mp3", "m4a", "wav", "aac", "png", "jpg", "jpeg", "gif", "webp", "bmp",
          "heic", "heif", "json", "xml", "html", "htm",
          "eml", "ics", "vcf", "psd", "ai", "tar", "gz", "7z",
        ]
        guard supportedExtensions.contains(ext.lowercased()) else { completion(nil); return }
        let hash = try Self.hashFile(source)
        let destination = folder.appendingPathComponent("\(hash).\(ext)")
        if !FileManager.default.fileExists(atPath: destination.path) {
          try FileManager.default.copyItem(at: source, to: destination)
          try Self.synchronize(destination)
        }
        try Self.protect(destination)
        let name = values.name ?? source.lastPathComponent
        let image = UTType(identifier)?.conforms(to: .image) == true ? Self.thumbnail(destination) : nil
        let draft = ShareDraft(id: hash, kind: "file", title: webpageTitle ?? name, value: destination.path, filename: name, typeIdentifier: identifier, temporary: true, preview: name + " · " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file), thumbnail: image)
        completion(draft)
      } catch { completion(nil) }
    }
  }

  private func loadImageFallback(
    _ provider: NSItemProvider,
    webpageTitle: String?,
    completion: @escaping (ShareDraft?) -> Void
  ) {
    guard provider.canLoadObject(ofClass: UIImage.self) else { completion(nil); return }
    provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
      guard let self, let image = object as? UIImage,
        let data = image.jpegData(compressionQuality: 0.92),
        Int64(data.count) <= self.maxFileBytes,
        let folder = self.filesFolder()
      else { completion(nil); return }
      do {
        let hash = Self.hash(data)
        let file = folder.appendingPathComponent("\(hash).jpg")
        if !FileManager.default.fileExists(atPath: file.path) {
          try data.write(to: file, options: .atomic)
          try Self.synchronize(file)
        }
        try Self.protect(file)
        completion(ShareDraft(
          id: hash,
          kind: "file",
          title: webpageTitle ?? "Shared image",
          value: file.path,
          filename: "Shared image.jpg",
          typeIdentifier: UTType.jpeg.identifier,
          temporary: true,
          preview: "Shared image · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))",
          thumbnail: image
        ))
      } catch { completion(nil) }
    }
  }

  private func filesFolder() -> URL? {
    guard let container = AppGroup.container else { return nil }
    let folder = container.appendingPathComponent("inbox_files", isDirectory: true)
    do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); return folder }
    catch { return nil }
  }

  private func save() {
    guard !model.saving else { return }
    guard !model.drafts.isEmpty else { model.error = "There is no supported content to save."; return }
    guard let tag = model.tags.first(where: { $0.id == model.selectedTag }) else {
      model.error = "Choose one existing Archive tag before saving."; return
    }
    model.saving = true
    model.error = nil
    let group = DispatchGroup()
    let lock = NSLock()
    var saved = 0
    var failed: [String] = []
    for draft in model.drafts {
      group.enter()
      DispatchQueue.global(qos: .utility).async {
        defer { group.leave() }
        do {
          try self.writeRequest(draft, tag: tag)
          lock.lock(); saved += 1; lock.unlock()
        } catch {
          lock.lock(); failed.append("\(draft.title): \(error.localizedDescription)"); lock.unlock()
        }
      }
    }
    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      self.model.saving = false
      if failed.isEmpty {
        self.model.message = "Saved \(saved) item\(saved == 1 ? "" : "s") to Archive."
          + (self.model.unsupportedCount == 0 ? "" : " \(self.model.unsupportedCount) other attachment(s) could not be read and were not saved.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
          self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
      } else {
        self.model.error = "Saved \(saved) of \(self.model.drafts.count). The rest remain available to retry. " + failed.joined(separator: " ")
      }
    }
  }

  private func writeRequest(_ draft: ShareDraft, tag: ArchiveTag) throws {
    guard let container = AppGroup.container else { throw ShareError.storage("App Group storage is unavailable") }
    let directory = container.appendingPathComponent("inbox_requests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var payload: [String: Any] = [
      "type": draft.kind == "url" ? "url" : draft.kind == "text" ? "text" : "file",
      "value": draft.value,
      "at": ISO8601DateFormatter().string(from: Date()),
      "source": "ios_share_sheet",
      "title": draft.title,
      "tagId": tag.id,
      "temporary": draft.temporary,
      "filename": draft.filename as Any? ?? NSNull(),
      "typeIdentifier": draft.typeIdentifier as Any? ?? NSNull(),
      "requestId": draft.id,
    ]
    if draft.kind == "url" {
      guard let url = URL(string: draft.value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
        throw ShareError.storage("The shared URL is invalid")
      }
      payload["url"] = url.absoluteString
    }
    let requestId = Self.hash(Data("\(draft.id)|\(tag.id)".utf8))
    let destination = directory.appendingPathComponent("\(requestId).json")
    if FileManager.default.fileExists(atPath: destination.path) { return }
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    try data.write(to: destination, options: .atomic)
    try Self.synchronize(destination)
    try Self.protect(destination)
    // Verify the durable marker before reporting success.
    let check = try Data(contentsOf: destination)
    guard (try JSONSerialization.jsonObject(with: check) as? [String: Any])?["tagId"] as? String == tag.id else {
      try? FileManager.default.removeItem(at: destination)
      throw ShareError.storage("The staged request could not be verified")
    }
  }

  private static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(32).description
  }

  private static func hashFile(_ file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(32).description
  }

  private static func synchronize(_ file: URL) throws {
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.synchronize()
  }

  private static func protect(_ file: URL) throws {
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: file.path
    )
  }

  private static func thumbnail(_ file: URL) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 160,
        ] as CFDictionary
      )
    else { return nil }
    return UIImage(cgImage: image)
  }
}

private enum ShareError: LocalizedError {
  case storage(String)
  var errorDescription: String? { if case .storage(let message) = self { return message }; return "Unable to save this item." }
}

private struct SharePopup: View {
  @ObservedObject var model: ShareModel
  let onSave: () -> Void

  var body: some View {
    ZStack {
      LinearGradient(colors: [Color(red: 0.99, green: 0.72, blue: 0.61), Color(red: 0.57, green: 0.53, blue: 0.91), Color(red: 0.12, green: 0.12, blue: 0.22)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
      VStack(alignment: .leading, spacing: 14) {
        HStack { Text("THEapp").font(.system(size: 16, weight: .bold, design: .rounded)); Spacer(); Text("ARCHIVE").font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(1.4).opacity(0.75) }
        if !model.rotationMessage.isEmpty { Text(model.rotationMessage).font(.system(size: 13, weight: .medium)).lineLimit(2).foregroundStyle(.white.opacity(0.88)) }
        if model.loading { ProgressView("Reading shared content…").tint(.white).frame(maxWidth: .infinity, alignment: .leading) }
        else if !model.drafts.isEmpty {
          ScrollView { VStack(spacing: 7) { ForEach(model.drafts) { draft in HStack(spacing: 10) { if let image = draft.thumbnail { Image(uiImage: image).resizable().scaledToFill().frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 7)) } else { Image(systemName: draft.kind == "url" ? "link" : draft.kind == "text" ? "text.alignleft" : "doc.fill").frame(width: 24) }; VStack(alignment: .leading, spacing: 2) { Text(draft.title).font(.system(size: 13, weight: .semibold)).lineLimit(1); Text(draft.preview).font(.system(size: 11)).lineLimit(2).foregroundStyle(.white.opacity(0.7)) } }.padding(10).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12)) } } }
          Text("Choose one Archive tag").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
          ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { ForEach(model.tags) { tag in Button { model.selectedTag = tag.id } label: { HStack(spacing: 6) { Circle().fill(Color(argb: tag.color)).frame(width: 8, height: 8); Text(tag.name).font(.system(size: 12, weight: .semibold)) }.padding(.horizontal, 11).padding(.vertical, 8).background(model.selectedTag == tag.id ? .white.opacity(0.3) : .white.opacity(0.1), in: Capsule()).overlay(Capsule().stroke(.white.opacity(model.selectedTag == tag.id ? 0.85 : 0.15))) }.buttonStyle(.plain) } } }
        }
        if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(Color(red: 1, green: 0.84, blue: 0.78)) }
        if let message = model.message { Label(message, systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(red: 0.75, green: 1, blue: 0.86)) }
        Button(action: onSave) { HStack { Spacer(); if model.saving { ProgressView().tint(.black) } else { Text("Save to Archive").font(.system(size: 15, weight: .bold)) }; Spacer() }.padding(.vertical, 13).foregroundStyle(Color(red: 0.15, green: 0.12, blue: 0.2)).background(.white, in: RoundedRectangle(cornerRadius: 14)) }.buttonStyle(.plain).disabled(model.loading || model.saving || model.drafts.isEmpty || model.selectedTag == nil || !model.errorIsRecoverable)
      }.padding(20).foregroundStyle(.white).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24)).overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.28))).padding(18)
    }
    .preferredColorScheme(.dark)
  }
}

private extension ShareModel {
  var errorIsRecoverable: Bool { !tags.isEmpty && !drafts.isEmpty && !loading }
}

private extension Color {
  init(argb: UInt32) {
    self.init(.sRGB, red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255, blue: Double(argb & 0xFF) / 255, opacity: Double((argb >> 24) & 0xFF) / 255)
  }
}
