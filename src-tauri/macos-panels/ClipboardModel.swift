import ApplicationServices
import AppKit
import Combine
import Foundation

@available(macOS 14, *)
@MainActor
final class ClipboardModel: ObservableObject {
  @Published private(set) var items: [ClipboardItem] = []
  @Published var query = "" {
    didSet { selectedIndex = displayedItems.isEmpty ? nil : 0 }
  }
  @Published private(set) var selectedIndex: Int?
  @Published private(set) var isPinned: Bool
  @Published private(set) var errorMessage: String?
  @Published private(set) var focusToken = 0

  var onDismiss: (() -> Void)?
  var onReleasePasteFocus: (() -> Void)?
  var onPinChange: ((Bool) -> Void)?

  private let repository: ClipboardRepository?
  private let imageCache: ImageCache?
  private let monitor: PasteboardMonitor
  private let pasteService: ClipboardPasteService
  private let sourceResolver = SourceApplicationResolver()
  private var state: ClipboardState
  private var targetApplicationBundleIdentifier: String?
  private weak var localTargetWindow: NSWindow?
  private weak var localTargetResponder: NSResponder?
  private let iconCache = NSCache<NSString, NSImage>()

  var displayedItems: [ClipboardItem] {
    ClipboardState.filtered(items, query: query)
  }

  static func live() -> ClipboardModel {
    let monitor = PasteboardMonitor()
    let pasteService = ClipboardPasteService()
    do {
      let root = try panelStorageDirectory()
      let model = ClipboardModel(
        repository: ClipboardRepository(url: root.appendingPathComponent("clipboard-history.json")),
        imageCache: ImageCache(rootURL: root.appendingPathComponent("ClipboardImages")),
        monitor: monitor,
        pasteService: pasteService,
        errorMessage: nil)
      model.connectAdapters()
      model.refreshItems()
      return model
    } catch {
      let model = ClipboardModel(
        repository: nil,
        imageCache: nil,
        monitor: monitor,
        pasteService: pasteService,
        errorMessage: error.localizedDescription)
      model.connectAdapters()
      return model
    }
  }

  private init(
    repository: ClipboardRepository?,
    imageCache: ImageCache?,
    monitor: PasteboardMonitor,
    pasteService: ClipboardPasteService,
    errorMessage: String?
  ) {
    self.repository = repository
    self.imageCache = imageCache
    self.monitor = monitor
    self.pasteService = pasteService
    self.errorMessage = errorMessage
    let pinned = UserDefaults.standard.bool(forKey: "liteNote.clipboardPinned")
    isPinned = pinned
    state = ClipboardState(isPinned: pinned)
  }

  func prepareForPresentation() {
    query = ""
    refreshItems()
    focusToken += 1
  }

  func moveSelection(_ direction: LauncherSelectionDirection) {
    let count = displayedItems.count
    guard count > 0 else {
      selectedIndex = nil
      return
    }
    let current = selectedIndex ?? 0
    switch direction {
    case .up:
      selectedIndex = (current - 1 + count) % count
    case .down:
      selectedIndex = (current + 1) % count
    }
  }

  func select(index: Int) {
    guard displayedItems.indices.contains(index) else { return }
    selectedIndex = index
  }

  func pasteSelected() {
    guard let selectedIndex, displayedItems.indices.contains(selectedIndex) else { return }
    do {
      let payload = try payload(for: displayedItems[selectedIndex])
      if let localTargetWindow {
        _ = pasteService.paste(
          payload,
          into: localTargetWindow,
          restoring: localTargetResponder)
      } else {
        let outcome = pasteService.paste(payload, into: targetApplicationBundleIdentifier) { [weak self] in
          self?.onReleasePasteFocus?()
        }
        if outcome == .pasteboardOnly {
          errorMessage = AXIsProcessTrusted() && CGPreflightPostEventAccess()
            ? "已复制，未能切回原应用，请手动按 ⌘V"
            : "已复制，请在系统设置的辅助功能中允许 Lite Note 自动粘贴"
          return
        }
        return
      }
      if state.shouldDismiss(after: .pasted) {
        onDismiss?()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func togglePinned() {
    isPinned.toggle()
    state.isPinned = isPinned
    UserDefaults.standard.set(isPinned, forKey: "liteNote.clipboardPinned")
    onPinChange?(isPinned)
  }

  func dismissForEscape() {
    onDismiss?()
  }

  func shouldDismissForFocusLoss() -> Bool {
    state.shouldDismiss(after: .focusLost)
  }

  func setCaptureEnabled(_ enabled: Bool) {
    if enabled { monitor.start() } else { monitor.stop() }
  }

  func updateTargetApplication(bundleIdentifier: String?) {
    guard
      let bundleIdentifier,
      bundleIdentifier != Bundle.main.bundleIdentifier
    else { return }
    localTargetWindow = nil
    localTargetResponder = nil
    targetApplicationBundleIdentifier = bundleIdentifier
  }

  func updateLocalPasteTarget(window: NSWindow, responder: NSResponder?) {
    localTargetWindow = window
    localTargetResponder = responder
    targetApplicationBundleIdentifier = nil
  }

  func sourceIcon(for item: ClipboardItem) -> NSImage? {
    guard let identifier = item.sourceBundleIdentifier else { return nil }
    let key = identifier as NSString
    if let cached = iconCache.object(forKey: key) { return cached }
    guard let icon = sourceResolver.icon(for: identifier) else { return nil }
    iconCache.setObject(icon, forKey: key)
    return icon
  }

  func thumbnail(for item: ClipboardItem) -> NSImage? {
    guard let path = item.thumbnailPath else { return nil }
    return NSImage(contentsOfFile: path)
  }

  func fileThumbnail(for item: ClipboardItem) -> NSImage? {
    guard
      let url = ClipboardState.imagePreviewURL(in: item.fileURLs),
      FileManager.default.fileExists(atPath: url.path)
    else { return nil }
    return NSImage(contentsOf: url)
  }

  func fileIcon(for url: URL) -> NSImage? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return NSWorkspace.shared.icon(forFile: url.path)
  }

  private func connectAdapters() {
    monitor.onCapture = { [weak self] payload, source in
      self?.record(payload, source: source)
    }
    pasteService.onPasteboardWrite = { [weak monitor] changeCount in
      monitor?.markOwnWrite(changeCount: changeCount)
    }
  }

  private func record(_ payload: ClipboardPayload, source: SourceApplication) {
    guard let repository else { return }
    do {
      let now = Date()
      let item: ClipboardItem
      switch payload {
      case .text(let text):
        item = ClipboardItem(
          kind: .text,
          text: text,
          sourceBundleIdentifier: source.bundleIdentifier,
          sourceApplicationName: source.name,
          contentHash: payload.contentHash,
          createdAt: now)
      case .image(let image, let thumbnail):
        guard
          let paths = try imageCache?.store(
            image: image,
            thumbnail: thumbnail,
            contentHash: payload.contentHash,
            createdAt: now)
        else { return }
        item = ClipboardItem(
          kind: .image,
          imagePath: paths.imagePath,
          thumbnailPath: paths.thumbnailPath,
          sourceBundleIdentifier: source.bundleIdentifier,
          sourceApplicationName: source.name,
          contentHash: payload.contentHash,
          createdAt: now)
      case .files(let urls):
        item = ClipboardItem(
          kind: .files,
          fileURLs: urls,
          sourceBundleIdentifier: source.bundleIdentifier,
          sourceApplicationName: source.name,
          contentHash: payload.contentHash,
          createdAt: now)
      }
      try repository.record(item)
      refreshItems()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func refreshItems() {
    guard let repository else { return }
    do {
      var fetched = try repository.fetchAll()
      let invalidFileItemIDs = fetched.compactMap { item -> UUID? in
        guard item.kind == .files else { return nil }
        return item.fileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
          ? nil : item.id
      }
      if !invalidFileItemIDs.isEmpty {
        try repository.delete(ids: invalidFileItemIDs)
        fetched = try repository.fetchAll()
      }

      let retainedPaths = Set(
        fetched.flatMap { item in
          [item.imagePath, item.thumbnailPath].compactMap { $0 }
        })
      let removedPaths = try imageCache?.cleanup(retaining: retainedPaths) ?? []
      if !removedPaths.isEmpty {
        let removedPathSet = Set(removedPaths.map(\.path))
        let recordsToRemove = fetched.compactMap { item -> UUID? in
          guard item.kind == .image else { return nil }
          return [item.imagePath, item.thumbnailPath].compactMap { $0 }
            .contains(where: removedPathSet.contains) ? item.id : nil
        }
        if !recordsToRemove.isEmpty {
          try repository.delete(ids: recordsToRemove)
          fetched = try repository.fetchAll()
        }
      }
      items = fetched
      selectedIndex = fetched.isEmpty ? nil : 0
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func payload(for item: ClipboardItem) throws -> ClipboardPayload {
    switch item.kind {
    case .text:
      return .text(item.text ?? "")
    case .image:
      guard
        let imagePath = item.imagePath,
        let thumbnailPath = item.thumbnailPath
      else { throw ClipboardModelError.missingContent }
      return .image(
        try Data(contentsOf: URL(fileURLWithPath: imagePath)),
        thumbnail: try Data(contentsOf: URL(fileURLWithPath: thumbnailPath)))
    case .files:
      let existingURLs = item.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
      guard !existingURLs.isEmpty else { throw ClipboardModelError.missingContent }
      return .files(existingURLs)
    }
  }
}

private enum ClipboardModelError: Error, LocalizedError {
  case missingContent

  var errorDescription: String? { "这条剪贴板内容已经失效" }
}
