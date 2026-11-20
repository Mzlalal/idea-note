import Foundation

public struct ClipboardRetentionResult: Equatable, Sendable {
  public let retained: [ClipboardItem]
  public let removed: [ClipboardItem]

  public init(retained: [ClipboardItem], removed: [ClipboardItem]) {
    self.retained = retained
    self.removed = removed
  }
}

public enum ClipboardRetention {
  public static func apply(
    to items: [ClipboardItem],
    maximumItemCount: Int = 150
  ) -> ClipboardRetentionResult {
    let sorted = items.sorted { $0.createdAt > $1.createdAt }
    let limit = max(0, maximumItemCount)
    return ClipboardRetentionResult(
      retained: Array(sorted.prefix(limit)),
      removed: Array(sorted.dropFirst(limit)).sorted { $0.createdAt < $1.createdAt })
  }
}
