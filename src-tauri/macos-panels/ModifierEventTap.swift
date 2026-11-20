import AppKit
import CoreGraphics
import IOKit.hidsystem

final class ModifierEventTap: @unchecked Sendable {
  var onEvent: ((ModifierEvent) -> Void)?

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var workspaceObserver: NSObjectProtocol?
  private var pressedModifiers: Set<PhysicalModifierKey> = []

  deinit {
    stop()
  }

  @discardableResult
  func start() -> Bool {
    guard eventTap == nil else { return true }

    let mask =
      CGEventMask(1 << CGEventType.flagsChanged.rawValue)
      | CGEventMask(1 << CGEventType.keyDown.rawValue)
      | CGEventMask(1 << CGEventType.keyUp.rawValue)
    guard
      let tap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: modifierEventTapCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque())
    else {
      return false
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    eventTap = tap
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.cancelForContextChange()
    }
    return true
  }

  func stop() {
    if let observer = workspaceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      workspaceObserver = nil
    }
    if let source = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
      runLoopSource = nil
    }
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
      self.eventTap = nil
    }
    pressedModifiers.removeAll()
  }

  fileprivate func handle(type: CGEventType, event: CGEvent) {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      }
      cancelForContextChange()
      return
    }

    let timestamp = ProcessInfo.processInfo.systemUptime
    switch type {
    case .flagsChanged:
      guard
        let key = Self.physicalModifier(
          for: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)))
      else {
        onEvent?(.ordinaryKey(at: timestamp, pressedModifiers: pressedModifiers))
        return
      }
      let phase: ModifierEventPhase = Self.isPressed(key, in: event.flags) ? .down : .up
      if phase == .down {
        pressedModifiers.insert(key)
      } else {
        pressedModifiers.remove(key)
      }
      onEvent?(
        ModifierEvent(
          physicalKey: key,
          phase: phase,
          timestamp: timestamp,
          pressedModifiers: pressedModifiers,
          isRepeat: false))
    case .keyDown, .keyUp:
      onEvent?(
        .ordinaryKey(
          at: timestamp,
          pressedModifiers: pressedModifiers))
    default:
      break
    }
  }

  private func cancelForContextChange() {
    pressedModifiers.removeAll()
    onEvent?(.contextChanged(at: ProcessInfo.processInfo.systemUptime))
  }

  private static func physicalModifier(for keyCode: CGKeyCode) -> PhysicalModifierKey? {
    switch keyCode {
    case 55: .leftCommand
    case 54: .rightCommand
    case 59: .leftControl
    case 62: .rightControl
    case 58: .leftOption
    case 61: .rightOption
    case 56: .leftShift
    case 60: .rightShift
    default: nil
    }
  }

  private static func isPressed(
    _ key: PhysicalModifierKey,
    in flags: CGEventFlags
  ) -> Bool {
    let mask: UInt64
    switch key {
    case .leftCommand: mask = UInt64(NX_DEVICELCMDKEYMASK)
    case .rightCommand: mask = UInt64(NX_DEVICERCMDKEYMASK)
    case .leftControl: mask = UInt64(NX_DEVICELCTLKEYMASK)
    case .rightControl: mask = UInt64(NX_DEVICERCTLKEYMASK)
    case .leftOption: mask = UInt64(NX_DEVICELALTKEYMASK)
    case .rightOption: mask = UInt64(NX_DEVICERALTKEYMASK)
    case .leftShift: mask = UInt64(NX_DEVICELSHIFTKEYMASK)
    case .rightShift: mask = UInt64(NX_DEVICERSHIFTKEYMASK)
    }
    return flags.rawValue & mask != 0
  }
}

private func modifierEventTapCallback(
  proxy _: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let monitor = Unmanaged<ModifierEventTap>.fromOpaque(userInfo).takeUnretainedValue()
  monitor.handle(type: type, event: event)
  return Unmanaged.passUnretained(event)
}
