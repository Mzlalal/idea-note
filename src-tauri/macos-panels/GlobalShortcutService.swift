import AppKit
import Carbon
import Foundation

enum GlobalShortcutError: Error, LocalizedError {
  case unsupportedKey(String)
  case registrationFailed(OSStatus)
  case eventHandlerInstallationFailed(OSStatus)

  var errorDescription: String? {
    switch self {
    case .unsupportedKey(let key):
      "不支持快捷键中的按键：\(key)"
    case .registrationFailed(let status):
      "快捷键已被其他应用占用，无法注册（\(status)）"
    case .eventHandlerInstallationFailed(let status):
      "无法启动系统快捷键监听（\(status)）"

    }
  }
}

final class GlobalShortcutService: @unchecked Sendable {
  var onShowNotes: (() -> Void)?
  var onShowLauncher: (() -> Void)?
  var onShowClipboard: (() -> Void)?

  private static let signature: OSType = 0x5444_4E54
  private let modifierEventTap: ModifierEventTap
  private var noteDetector: DoubleModifierDetector?
  private var launcherDetector: DoubleModifierDetector?
  private var hotKeyRef: EventHotKeyRef?
  private var hotKeyChord: ShortcutChord?
  private var eventHandler: EventHandlerRef?
  private var eventHandlerStatus: OSStatus = noErr

  init(modifierEventTap: ModifierEventTap = ModifierEventTap()) {
    self.modifierEventTap = modifierEventTap
    installHotKeyHandler()
    modifierEventTap.onEvent = { [weak self] event in
      DispatchQueue.main.async {
        self?.consume(event)
      }
    }
  }

  deinit {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
    }
    modifierEventTap.stop()
  }

  func startModifierMonitoring() -> Bool {
    modifierEventTap.start()
  }

  func stopModifierMonitoring() {
    modifierEventTap.stop()
  }

  func update(configuration: ShortcutConfiguration) throws {
    try configuration.validate()
    let interval = NSEvent.doubleClickInterval
    noteDetector = configuration.noteModifier.map {
      DoubleModifierDetector(target: $0, systemDoubleClickInterval: interval)
    }
    launcherDetector = configuration.launcherModifier.map {
      DoubleModifierDetector(target: $0, systemDoubleClickInterval: interval)
    }
    guard eventHandlerStatus == noErr else {
      throw GlobalShortcutError.eventHandlerInstallationFailed(eventHandlerStatus)
    }
    let previousRef = hotKeyRef
    let previousChord = hotKeyChord

    var replacementRef: EventHotKeyRef?
    if configuration.clipboardShortcut != previousChord,
      let chord = configuration.clipboardShortcut
    {
      replacementRef = try register(chord: chord, identifier: 2)
    }

    if configuration.clipboardShortcut != previousChord {
      if let previousRef {
        UnregisterEventHotKey(previousRef)
      }
      hotKeyRef = replacementRef
      hotKeyChord = configuration.clipboardShortcut
    }


  }

  private func installHotKeyHandler() {
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed))
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      globalHotKeyHandler,
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandler)
    if status != noErr {
      eventHandler = nil
      eventHandlerStatus = status
    }
  }

  private func register(chord: ShortcutChord, identifier: UInt32) throws -> EventHotKeyRef {
    guard let keyCode = Self.carbonKeyCode(for: chord.key) else {
      throw GlobalShortcutError.unsupportedKey(chord.key)
    }
    var reference: EventHotKeyRef?
    let identifier = EventHotKeyID(signature: Self.signature, id: identifier)
    let status = RegisterEventHotKey(
      keyCode,
      Self.carbonModifiers(for: chord.modifiers),
      identifier,
      GetApplicationEventTarget(),
      0,
      &reference)
    guard status == noErr, let reference else {
      throw GlobalShortcutError.registrationFailed(status)
    }
    return reference
  }

  private func consume(_ event: ModifierEvent) {
    let noteResult = noteDetector?.consume(event)
    let launcherResult = launcherDetector?.consume(event)
    if noteResult == .triggered {
      onShowNotes?()
    } else if launcherResult == .triggered {
      onShowLauncher?()
    }
  }

  fileprivate func handleHotKey(event: EventRef?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
      event,
      EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID),
      nil,
      MemoryLayout<EventHotKeyID>.size,
      nil,
      &identifier)
    guard status == noErr,
      identifier.signature == Self.signature
    else { return OSStatus(eventNotHandledErr) }
    onShowClipboard?()
    return noErr
  }

  private static func carbonModifiers(for modifiers: Set<ShortcutModifier>) -> UInt32 {
    modifiers.reduce(into: UInt32(0)) { result, modifier in
      switch modifier {
      case .command: result |= UInt32(cmdKey)
      case .control: result |= UInt32(controlKey)
      case .option: result |= UInt32(optionKey)
      case .shift: result |= UInt32(shiftKey)
      }
    }
  }

  private static func carbonKeyCode(for key: String) -> UInt32? {
    let normalized = key.lowercased()
    let keyCodes: [String: Int] = [
      "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
      "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
      "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
      "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
      "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
      "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
      "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
      "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
      "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
      "8": kVK_ANSI_8, "9": kVK_ANSI_9,
      "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab,
    ]
    return keyCodes[normalized].map(UInt32.init)
  }
}

private func globalHotKeyHandler(
  nextHandler _: EventHandlerCallRef?,
  event: EventRef?,
  userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let userData else { return OSStatus(eventNotHandledErr) }
  let service = Unmanaged<GlobalShortcutService>.fromOpaque(userData).takeUnretainedValue()
  return service.handleHotKey(event: event)
}
