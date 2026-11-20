import AppKit
import Foundation

@MainActor
final class PasteboardMonitor {
  typealias CaptureHandler = (ClipboardPayload, SourceApplication) -> Void

  var onCapture: CaptureHandler?

  private let pasteboard: NSPasteboard
  private let sourceResolver: SourceApplicationResolver
  private var tracker: ClipboardChangeTracker
  private var timer: Timer?

  init(
    pasteboard: NSPasteboard = .general,
    sourceResolver: SourceApplicationResolver = SourceApplicationResolver()
  ) {
    self.pasteboard = pasteboard
    self.sourceResolver = sourceResolver
    tracker = ClipboardChangeTracker(initialChangeCount: pasteboard.changeCount)
  }

  func start() {
    guard timer == nil else { return }
    tracker = ClipboardChangeTracker(initialChangeCount: pasteboard.changeCount)
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.poll() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  func markOwnWrite(changeCount: Int) {
    tracker.markOwnWrite(changeCount: changeCount)
  }

  private func poll() {
    guard timer != nil, tracker.shouldCapture(changeCount: pasteboard.changeCount) else { return }
    let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
    guard let payload = ClipboardAdapter.payload(from: snapshot) else { return }
    onCapture?(payload, sourceResolver.frontmostApplication())
  }
}

private struct PasteboardSnapshot: ClipboardReading {
  let changeCount: Int
  let fileURLs: [URL]
  let imageData: Data?
  let thumbnailData: Data?
  let text: String?

  @MainActor
  init(pasteboard: NSPasteboard) {
    changeCount = pasteboard.changeCount
    fileURLs =
      pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    text = pasteboard.string(forType: .string)

    let rawImageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
    if let rawImageData, let image = NSImage(data: rawImageData) {
      imageData = image.pngData(maximumDimension: nil)
      thumbnailData = image.pngData(maximumDimension: 112)
    } else {
      imageData = nil
      thumbnailData = nil
    }
  }
}

extension NSImage {
  fileprivate func pngData(maximumDimension: CGFloat?) -> Data? {
    let outputImage: NSImage
    if let maximumDimension, max(size.width, size.height) > maximumDimension {
      let scale = maximumDimension / max(size.width, size.height)
      let targetSize = NSSize(width: size.width * scale, height: size.height * scale)
      outputImage = NSImage(size: targetSize, flipped: false) { rect in
        self.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        return true
      }
    } else {
      outputImage = self
    }
    guard
      let tiffData = outputImage.tiffRepresentation,
      let representation = NSBitmapImageRep(data: tiffData)
    else { return nil }
    return representation.representation(using: .png, properties: [:])
  }
}
