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
  /// Set once the request files are durably written; blocks any further save.
  @Published var finished = false
  @Published var error: String?
  /// Chosen once in viewDidLoad; no UI update re-rolls it.
  @Published var greeting = ""
  @Published var unsupportedCount = 0
}

final class ShareViewController: UIViewController {
  private let model = ShareModel()
  private let maxFileBytes: Int64 = 300 * 1024 * 1024
  private let maxTextChars = 200_000

  // iOS presents a custom share extension as a modal sheet; with the default
  // style that sheet is an opaque system card (the black full-screen surface).
  // Over-full-screen keeps the app the user is sharing from visible behind us,
  // so the floating popup is the only thing THEapp draws.
  override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
    super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    modalPresentationStyle = .overFullScreen
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    modalPresentationStyle = .overFullScreen
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    model.greeting = ShareGreetings.random()
    let host = UIHostingController(rootView: SharePopup(model: model, onSave: { [weak self] in
      self?.save()
    }, onCancel: { [weak self] in
      self?.cancel()
    }))
    addChild(host)
    host.view.backgroundColor = .clear
    host.view.isOpaque = false
    view.isOpaque = false
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

  private func cancel() {
    guard !model.saving, !model.finished else { return }
    extensionContext?.cancelRequest(
      withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
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
    guard !model.saving, !model.finished else { return }
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
        // Every request file is on disk and verified: close the whole sheet and
        // return to the app the user came from.
        self.model.finished = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
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

// MARK: popup

/// Where the floating window sits inside the area iOS gives the extension.
/// About 74% x 60% of it, centred, a little below the middle, and never closer
/// than `margin` to any edge (small screens shrink it instead of clipping it).
private struct PopupMetrics {
  static let margin: CGFloat = 16
  static let radius: CGFloat = 24

  let width: CGFloat
  let height: CGFloat
  let centerX: CGFloat
  let centerY: CGFloat

  init(container: CGSize) {
    let room = max(container.width - 2 * Self.margin, 1)
    let tall = max(container.height - 2 * Self.margin, 1)
    // 74% of the width, but not narrower than 280pt when the screen allows it.
    let popupWidth = min(max(container.width * 0.74, min(280, room)), room)
    // 60% of the height, but never shorter than 430pt when there is room, so
    // the content always fits.
    let popupHeight = min(max(container.height * 0.60, min(430, tall)), tall)
    let wanted = container.height / 2 + container.height * 0.04
    width = popupWidth
    height = popupHeight
    centerX = container.width / 2
    centerY = min(wanted, container.height - Self.margin - popupHeight / 2)
  }
}

private extension Font {
  /// Every word in the popup: SF Pro, bold.
  static func share(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
}

private struct SharePopup: View {
  @ObservedObject var model: ShareModel
  let onSave: () -> Void
  let onCancel: () -> Void

  private var canSave: Bool {
    !model.loading && !model.saving && !model.finished && !model.drafts.isEmpty
      && !model.tags.isEmpty && model.selectedTag != nil
  }

  var body: some View {
    GeometryReader { proxy in
      let metrics = PopupMetrics(container: proxy.size)
      ZStack {
        // No dimming or background of our own: this layer is fully transparent
        // and only catches taps outside the popup (tap outside = cancel).
        Color.clear
          .ignoresSafeArea()
          .contentShape(Rectangle())
          .onTapGesture { onCancel() }
        popup
          .frame(width: metrics.width, height: metrics.height)
          .position(x: metrics.centerX, y: metrics.centerY)
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .environment(\.colorScheme, .dark)
  }

  private var popup: some View {
    ZStack {
      PhotoBackdrop()
      VStack(spacing: 0) {
        HStack {
          Text("misc.").font(.share(13)).foregroundColor(.white)
          Spacer()
        }
        Spacer(minLength: 10)
        Text(model.greeting)
          .font(.share(22))
          .foregroundColor(.white)
          .multilineTextAlignment(.center)
          .minimumScaleFactor(0.7)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity)
        Spacer(minLength: 14)
        glassContainer
        if let error = model.error {
          Text(error)
            .font(.share(11))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .padding(.top, 8)
        }
        Spacer(minLength: 10)
        doneButton
      }
      .padding(18)
    }
    .clipShape(RoundedRectangle(cornerRadius: PopupMetrics.radius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: PopupMetrics.radius, style: .continuous)
        .stroke(Color.white.opacity(0.2), lineWidth: 1))
    .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 8)
  }

  // ONE continuous glass surface: the link on top, the tags below it.
  private var glassContainer: some View {
    VStack(alignment: .leading, spacing: 0) {
      linkSection
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
      Rectangle().fill(Color.white.opacity(0.22)).frame(height: 1)
      tagSection
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Material.ultraThinMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(Color.white.opacity(0.28), lineWidth: 1))
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private var linkSection: some View {
    VStack(alignment: .leading, spacing: 3) {
      if model.loading {
        ProgressView().tint(.white)
      } else if let first = model.drafts.first {
        Text(Self.shown(first))
          .font(.share(14))
          .foregroundColor(.white)
          .lineLimit(first.kind == "url" ? 1 : 2)
          .truncationMode(first.kind == "url" ? .middle : .tail)
        if model.drafts.count > 1 {
          Text("+\(model.drafts.count - 1) more")
            .font(.share(11))
            .foregroundColor(.white)
        }
      } else {
        // Nothing readable was shared; the reason is printed under the card.
        Color.clear.frame(height: 18)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// What is written on screen. The saved value is always draft.value, the full
  /// original URL; only this display text drops the scheme.
  private static func shown(_ draft: ShareDraft) -> String {
    guard draft.kind == "url" else { return draft.title }
    var text = draft.value
    for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
      text = String(text.dropFirst(scheme.count))
      break
    }
    if text.hasSuffix("/") { text.removeLast() }
    return text
  }

  private var tagSection: some View {
    ScrollView(.vertical, showsIndicators: false) {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 76), spacing: 8)],
        alignment: .leading,
        spacing: 8
      ) {
        ForEach(model.tags) { tag in
          let selected = model.selectedTag == tag.id
          Button {
            if !model.saving && !model.finished { model.selectedTag = tag.id }
          } label: {
            HStack(spacing: 5) {
              if selected {
                Image(systemName: "checkmark")
                  .font(.system(size: 9, weight: .bold))
                  .foregroundColor(.white)
              } else {
                Circle().fill(Color(argb: tag.color)).frame(width: 7, height: 7)
              }
              Text(tag.name)
                .font(.share(12))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.3 : 0))
            )
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(selected ? 0.95 : 0.25), lineWidth: selected ? 1.5 : 1)
            )
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selected ? .isSelected : [])
        }
      }
      .padding(12)
    }
  }

  // Outside the glass, small and quiet.
  private var doneButton: some View {
    Button(action: onSave) {
      ZStack {
        if model.saving {
          ProgressView().tint(.white)
        } else {
          Text("done.").font(.share(15)).foregroundColor(.white)
        }
      }
      .frame(minWidth: 64, minHeight: 20)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(Capsule().fill(Color.white.opacity(0.14)))
      .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .disabled(!canSave)
    .opacity(canSave || model.saving ? 1 : 0.45)
    .frame(maxWidth: .infinity)
  }
}

/// The supplied reference photograph itself (SharePopupBackground.webp, the
/// exact file, unedited), filling the popup. The colour wash underneath only
/// shows if the image could not be loaded, so the popup is never blank.
private struct PhotoBackdrop: View {
  private static let photo: UIImage? = Bundle.main
    .path(forResource: "SharePopupBackground", ofType: "webp")
    .flatMap { UIImage(contentsOfFile: $0) }

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Color(red: 0.12, green: 0.30, blue: 0.48)
        if let photo = Self.photo {
          Image(uiImage: photo)
            .resizable()
            .scaledToFill()
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      .clipped()
    }
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
