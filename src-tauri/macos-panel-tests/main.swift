import AppKit

@MainActor
func verifyPanels() {
  _ = NSApplication.shared
  let launcher = LauncherPanelController()
  let clipboard = ClipboardPanelController()
  for panel in [launcher.window, clipboard.window] {
    precondition(panel.styleMask.contains(.nonactivatingPanel))
    precondition(!panel.canBecomeMain && panel.canBecomeKey)
    precondition(!panel.styleMask.contains(.titled))
  }

  precondition(panelAction(enabled: false, visible: false) == .none)
  precondition(panelAction(enabled: true, visible: false) == .show)
  precondition(panelAction(enabled: true, visible: true) == .hide)
  precondition(!shouldDismissPanel(pinned: false, peerHasFocus: true))
  precondition(shouldDismissPanel(pinned: false, peerHasFocus: false))
  precondition(!shouldDismissPanel(pinned: true, peerHasFocus: false))

  let editor = NSWindow(
    contentRect: NSRect(x: 30, y: 30, width: 400, height: 300),
    styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
  editor.isReleasedWhenClosed = false
  editor.orderOut(nil)
  let suite = "LiteNote.QuickPanels.Tests.\(UUID())"
  let defaults = UserDefaults(suiteName: suite)!
  let panels = QuickPanels(defaults: defaults, callback: { _, _, _ in
    preconditionFailure("Panel presentation must never call the editor bridge")
  })
  defer {
    panels.stop()
    defaults.removePersistentDomain(forName: suite)
  }
  precondition(panels.enabled(0) && panels.enabled(1) && !panels.enabled(2))
  for first: Int32 in [0, 1] {
    let second = 1 - first
    panels.toggle(first)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    precondition(panels.visible(first) && !editor.isVisible)
    panels.toggle(second)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    precondition(panels.visible(first) && panels.visible(second) && !editor.isVisible)
    panels.toggle(first)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    precondition(!panels.visible(first) && panels.visible(second) && !editor.isVisible)
    panels.toggle(second)
  }
  panels.configure(0, enabled: false)
  panels.toggle(0)
  precondition(!panels.visible(0) && !editor.isVisible)
  panels.toggle(1)
  precondition(panels.visible(1))
  panels.configure(1, enabled: false)
  panels.toggle(1)
  precondition(!panels.visible(1) && !editor.isVisible)

  panels.configure(2, enabled: true)
  precondition(panels.enabled(2) && NSApp.activationPolicy() == .regular)
  panels.configure(2, enabled: false)
  precondition(!panels.enabled(2) && NSApp.activationPolicy() == .accessory)

  let historyURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("LiteNoteClipboardTest-\(UUID()).json")
  defer { try? FileManager.default.removeItem(at: historyURL) }
  let history = ClipboardRepository(url: historyURL)
  do {
    let original = ClipboardItem(kind: .text, text: "test", contentHash: "same", createdAt: .distantPast)
    let repeated = ClipboardItem(kind: .text, text: "test", contentHash: "same", createdAt: .now)
    try history.record(original)
    try history.record(repeated)
    let items = try ClipboardRepository(url: historyURL).fetchAll()
    precondition(items == [repeated])
  } catch {
    preconditionFailure("Clipboard history round trip failed: \(error)")
  }

  var command = DoubleModifierDetector(target: .command)
  var control = DoubleModifierDetector(target: .control)
  for (index, phase) in [ModifierEventPhase.down, .up, .down, .up].enumerated() {
    let event = ModifierEvent(
      physicalKey: .leftCommand, phase: phase, timestamp: Double(index) * 0.05,
      pressedModifiers: phase == .down ? [.leftCommand] : [], isRepeat: false)
    precondition((command.consume(event) == .triggered) == (index == 3))
    precondition(control.consume(event) != .triggered)
  }

  let files = [
    LauncherDocument(path: "/workspace/a/文档.md", title: "文档", detail: "a/文档.md"),
    LauncherDocument(path: "/workspace/b/文档.md", title: "文档", detail: "b/文档.md"),
    LauncherDocument(path: "/workspace/other.md", title: "Other", detail: "文档"),
  ]
  precondition(LauncherDocument.matching(files, query: " ").isEmpty)
  precondition(LauncherDocument.matching(files, query: "文档") == Array(files.prefix(2)))
  precondition(LauncherDocument.matching(files, query: " OTHER ") == [files[2]])
}

verifyPanels()
