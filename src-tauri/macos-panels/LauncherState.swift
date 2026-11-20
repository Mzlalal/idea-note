import Foundation

public enum LauncherMode: Equatable, Sendable {
  case recentGrid
  case resultsList
}

public enum LauncherSelectionDirection: Sendable {
  case up
  case down
}

public enum LauncherIntent: Sendable {
  case activateSelection
  case escape
}

public enum LauncherEffect: Equatable, Sendable {
  case none
  case activate(index: Int)
  case dismiss
}

public struct LauncherState: Equatable, Sendable {
  public static let recentLimit = 10

  public private(set) var query: String
  public private(set) var mode: LauncherMode
  public private(set) var visibleItemCount: Int
  public private(set) var selectedIndex: Int?

  public init(query: String = "", availableCount: Int = 0) {
    self.query = query
    mode =
      query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? .recentGrid : .resultsList
    visibleItemCount = 0
    selectedIndex = nil
    update(query: query, availableCount: availableCount)
  }

  public mutating func update(query: String, availableCount: Int) {
    self.query = query
    mode =
      query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? .recentGrid : .resultsList
    visibleItemCount = max(
      0,
      min(mode == .recentGrid ? Self.recentLimit : availableCount, availableCount))
    selectedIndex = visibleItemCount > 0 && mode == .resultsList ? 0 : nil
  }

  public mutating func moveSelection(_ direction: LauncherSelectionDirection) {
    guard visibleItemCount > 0 else {
      selectedIndex = nil
      return
    }
    guard let current = selectedIndex else {
      selectedIndex = direction == .down ? 0 : visibleItemCount - 1
      return
    }
    switch direction {
    case .up:
      selectedIndex = (current - 1 + visibleItemCount) % visibleItemCount
    case .down:
      selectedIndex = (current + 1) % visibleItemCount
    }
  }

  public mutating func select(index: Int) {
    guard (0..<visibleItemCount).contains(index) else { return }
    selectedIndex = index
  }

  public func handle(_ intent: LauncherIntent) -> LauncherEffect {
    switch intent {
    case .activateSelection:
      selectedIndex.map(LauncherEffect.activate(index:)) ?? .none
    case .escape:
      .dismiss
    }
  }
}
