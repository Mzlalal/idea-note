import Foundation

public protocol ClipboardReading: Sendable {
  var changeCount: Int { get }
  var fileURLs: [URL] { get }
  var imageData: Data? { get }
  var thumbnailData: Data? { get }
  var text: String? { get }
}

public enum ClipboardAdapter {
  public static func payload(from pasteboard: some ClipboardReading) -> ClipboardPayload? {
    if !pasteboard.fileURLs.isEmpty {
      return .files(pasteboard.fileURLs)
    }
    if let imageData = pasteboard.imageData {
      return .image(imageData, thumbnail: pasteboard.thumbnailData ?? imageData)
    }
    if let text = pasteboard.text,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return .text(text)
    }
    return nil
  }
}

public struct ClipboardChangeTracker: Equatable, Sendable {
  private var lastObservedChangeCount: Int
  private var ownWriteChangeCounts: Set<Int> = []

  public init(initialChangeCount: Int) {
    lastObservedChangeCount = initialChangeCount
  }

  public mutating func markOwnWrite(changeCount: Int) {
    ownWriteChangeCounts.insert(changeCount)
  }

  public mutating func shouldCapture(changeCount: Int) -> Bool {
    guard changeCount != lastObservedChangeCount else { return false }
    lastObservedChangeCount = changeCount
    if ownWriteChangeCounts.remove(changeCount) != nil {
      return false
    }
    ownWriteChangeCounts = ownWriteChangeCounts.filter { $0 > changeCount }
    return true
  }
}

public enum ClipboardPasteOutcome: Equatable, Sendable {
  case pasteboardOnly
  case pasteAndInsert
}

public enum ClipboardPresentationTarget: Equatable, Sendable {
  case local
  case external(String)
  case unavailable

  public static func resolve(
    frontmostBundleIdentifier: String?,
    ownBundleIdentifier: String?,
    hasLocalWindow: Bool
  ) -> ClipboardPresentationTarget {
    guard let frontmostBundleIdentifier else { return .unavailable }
    if frontmostBundleIdentifier == ownBundleIdentifier {
      return hasLocalWindow ? .local : .unavailable
    }
    return .external(frontmostBundleIdentifier)
  }
}

public enum ClipboardPastePolicy {
  public static func outcome(
    accessibilityGranted: Bool,
    targetAvailable: Bool = true
  ) -> ClipboardPasteOutcome {
    accessibilityGranted && targetAvailable ? .pasteAndInsert : .pasteboardOnly
  }
}
