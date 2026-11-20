import Foundation

public enum PhysicalModifierKey: String, CaseIterable, Sendable {
  case leftCommand
  case rightCommand
  case leftControl
  case rightControl
  case leftOption
  case rightOption
  case leftShift
  case rightShift

  public var modifier: DoubleModifierKey {
    switch self {
    case .leftCommand, .rightCommand: .command
    case .leftControl, .rightControl: .control
    case .leftOption, .rightOption: .option
    case .leftShift, .rightShift: .shift
    }
  }
}

public enum ModifierEventPhase: Sendable {
  case down
  case up
  case ordinaryKey
  case contextChanged
}

public struct ModifierEvent: Sendable {
  public let physicalKey: PhysicalModifierKey?
  public let phase: ModifierEventPhase
  public let timestamp: TimeInterval
  public let pressedModifiers: Set<PhysicalModifierKey>
  public let isRepeat: Bool

  public init(
    physicalKey: PhysicalModifierKey?,
    phase: ModifierEventPhase,
    timestamp: TimeInterval,
    pressedModifiers: Set<PhysicalModifierKey>,
    isRepeat: Bool = false
  ) {
    self.physicalKey = physicalKey
    self.phase = phase
    self.timestamp = timestamp
    self.pressedModifiers = pressedModifiers
    self.isRepeat = isRepeat
  }

  public static func modifier(
    _ key: PhysicalModifierKey,
    _ phase: ModifierEventPhase,
    at timestamp: TimeInterval,
    pressedModifiers: Set<PhysicalModifierKey>? = nil,
    isRepeat: Bool = false
  ) -> ModifierEvent {
    ModifierEvent(
      physicalKey: key,
      phase: phase,
      timestamp: timestamp,
      pressedModifiers: pressedModifiers ?? (phase == .down ? [key] : []),
      isRepeat: isRepeat)
  }

  public static func ordinaryKey(
    at timestamp: TimeInterval,
    pressedModifiers: Set<PhysicalModifierKey> = []
  ) -> ModifierEvent {
    ModifierEvent(
      physicalKey: nil,
      phase: .ordinaryKey,
      timestamp: timestamp,
      pressedModifiers: pressedModifiers)
  }

  public static func contextChanged(at timestamp: TimeInterval) -> ModifierEvent {
    ModifierEvent(
      physicalKey: nil,
      phase: .contextChanged,
      timestamp: timestamp,
      pressedModifiers: [])
  }
}

public enum DetectionResult: Equatable, Sendable {
  case none
  case triggered
}

public struct DoubleModifierDetector: Sendable {
  public let target: DoubleModifierKey
  public let maximumInterval: TimeInterval

  private enum State: Sendable {
    case idle
    case firstDown(key: PhysicalModifierKey, at: TimeInterval)
    case firstUp(key: PhysicalModifierKey, at: TimeInterval)
    case secondDown(key: PhysicalModifierKey, at: TimeInterval)
    case waitingForRelease
  }

  private var state: State = .idle

  public init(
    target: DoubleModifierKey,
    systemDoubleClickInterval: TimeInterval = 0.35
  ) {
    self.target = target
    maximumInterval = min(max(systemDoubleClickInterval, 0.25), 0.4)
  }

  @discardableResult
  public mutating func consume(_ event: ModifierEvent) -> DetectionResult {
    if event.isRepeat || event.phase == .ordinaryKey || event.phase == .contextChanged {
      state = event.pressedModifiers.isEmpty ? .idle : .waitingForRelease
      return .none
    }

    if case .waitingForRelease = state {
      if event.pressedModifiers.isEmpty {
        state = .idle
      }
      return .none
    }

    guard let key = event.physicalKey, key.modifier == target else {
      state = event.pressedModifiers.isEmpty ? .idle : .waitingForRelease
      return .none
    }

    switch state {
    case .idle:
      if isCleanDown(event, key: key) {
        state = .firstDown(key: key, at: event.timestamp)
      }
    case .firstDown(let expectedKey, let downAt):
      if event.phase == .up,
        key == expectedKey,
        event.pressedModifiers.isEmpty,
        event.timestamp - downAt <= maximumInterval
      {
        state = .firstUp(key: key, at: event.timestamp)
      } else {
        cancel(for: event)
      }
    case .firstUp(let expectedKey, let releasedAt):
      if isCleanDown(event, key: expectedKey),
        key == expectedKey,
        event.timestamp - releasedAt <= maximumInterval
      {
        state = .secondDown(key: key, at: event.timestamp)
      } else if isCleanDown(event, key: key) {
        state = .firstDown(key: key, at: event.timestamp)
      } else {
        cancel(for: event)
      }
    case .secondDown(let expectedKey, let downAt):
      if event.phase == .up,
        key == expectedKey,
        event.timestamp - downAt <= maximumInterval
      {
        guard event.pressedModifiers.isEmpty else {
          state = .waitingForRelease
          return .none
        }
        state = .idle
        return .triggered
      }
      cancel(for: event)
    case .waitingForRelease:
      break
    }
    return .none
  }

  public mutating func reset() {
    state = .idle
  }

  private func isCleanDown(_ event: ModifierEvent, key: PhysicalModifierKey) -> Bool {
    event.phase == .down && !event.isRepeat && event.pressedModifiers == [key]
  }

  private mutating func cancel(for event: ModifierEvent) {
    state = event.pressedModifiers.isEmpty ? .idle : .waitingForRelease
  }
}
