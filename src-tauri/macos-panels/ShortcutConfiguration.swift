import Foundation

public enum ShortcutConfigurationError: Error, Equatable, Sendable {
  case duplicateDoubleModifier(DoubleModifierKey)
  case clipboardShortcutRequiresModifier
  case clipboardShortcutRequiresKey
  case reservedClipboardShortcut(ShortcutChord)
}

public struct ShortcutConfiguration: Equatable, Sendable {
  public var noteModifier: DoubleModifierKey?
  public var launcherModifier: DoubleModifierKey?
  public var clipboardShortcut: ShortcutChord?

  public init(
    noteModifier: DoubleModifierKey? = .control,
    launcherModifier: DoubleModifierKey? = .command,
    clipboardShortcut: ShortcutChord? = ShortcutChord(
      modifiers: [.command, .shift],
      key: "v")
  ) {
    self.noteModifier = noteModifier
    self.launcherModifier = launcherModifier
    self.clipboardShortcut = clipboardShortcut
  }

  public func validate() throws {
    if let noteModifier, noteModifier == launcherModifier {
      throw ShortcutConfigurationError.duplicateDoubleModifier(noteModifier)
    }
    guard let clipboardShortcut else { return }
    guard !clipboardShortcut.modifiers.isEmpty else {
      throw ShortcutConfigurationError.clipboardShortcutRequiresModifier
    }
    guard !clipboardShortcut.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ShortcutConfigurationError.clipboardShortcutRequiresKey
    }
    let reserved = [
      ShortcutChord(modifiers: [.command], key: "space"),
      ShortcutChord(modifiers: [.command], key: "tab"),
      ShortcutChord(modifiers: [.command], key: "`"),
    ]
    if reserved.contains(clipboardShortcut) {
      throw ShortcutConfigurationError.reservedClipboardShortcut(clipboardShortcut)
    }
  }
}

public enum ShortcutModifier: String, Codable, Hashable, Sendable {
  case command
  case control
  case option
  case shift
}

public struct ShortcutChord: Codable, Equatable, Sendable {
  public var modifiers: Set<ShortcutModifier>
  public var key: String

  public init(modifiers: Set<ShortcutModifier>, key: String) {
    self.modifiers = modifiers
    self.key = key.lowercased()
  }
}
public enum DoubleModifierKey: String, Codable, CaseIterable, Sendable {
  case command
  case control
  case option
  case shift
}
