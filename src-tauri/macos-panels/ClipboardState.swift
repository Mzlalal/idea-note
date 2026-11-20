import Foundation
import UniformTypeIdentifiers

public enum ClipboardDismissEvent: Sendable {
  case focusLost
  case pasted
  case escape
}

@available(macOS 11, *)

public struct ClipboardState: Equatable, Sendable {
  public var isPinned: Bool

  public init(isPinned: Bool = false) {
    self.isPinned = isPinned
  }

  public static let minimumRowHeight: Double = 56
  public static let maximumRowHeight: Double = 84

  public static func sourceIconSlotWidth(hasIcon: Bool) -> Double {
    hasIcon ? 36 : 0
  }

  @available(macOS 11, *)

  public static func imagePreviewURL(in fileURLs: [URL]) -> URL? {
    fileURLs.first { url in
      guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
      return type.conforms(to: .image)
    }
  }

  public static func filePathSummary(for url: URL) -> String? {
    imagePreviewURL(in: [url]) == nil ? url.deletingLastPathComponent().path : nil
  }

  public static func fileName(for url: URL) -> String? {
    imagePreviewURL(in: [url]) == nil ? url.lastPathComponent : nil
  }

  public static func filtered(_ items: [ClipboardItem], query: String) -> [ClipboardItem] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return items }
    return items.filter { item in
      switch item.kind {
      case .text:
        item.text?.localizedCaseInsensitiveContains(query) == true
      case .image:
        false
      case .files:
        item.fileURLs.contains {
          $0.lastPathComponent.localizedCaseInsensitiveContains(query)
            || $0.path.localizedCaseInsensitiveContains(query)
        }
      }
    }
  }

  public func shouldDismiss(after event: ClipboardDismissEvent) -> Bool {
    switch event {
    case .escape:
      true
    case .focusLost, .pasted:
      !isPinned
    }
  }
}
