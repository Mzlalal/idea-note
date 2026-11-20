import AppKit
import ApplicationServices
import CoreGraphics

typealias PanelCallback = @convention(c) (Int32, Int64, UnsafePointer<CChar>?) -> Void

@available(macOS 14, *)
@MainActor
final class QuickPanels {
  static var shared: QuickPanels?

  private lazy var launcher = makeLauncher()
  private lazy var clipboard = makeClipboard()
  private lazy var shortcuts = GlobalShortcutService()
  private let callback: PanelCallback
  private let defaults: UserDefaults
  private var shortcutError: String?
  private var clickMonitor: Any?
  private var permissionTimer: Timer?
  private var modifierMonitoring = false

  init(defaults: UserDefaults = .standard, callback: @escaping PanelCallback) {
    self.defaults = defaults
    self.callback = callback
    defaults.register(defaults: [
      "liteNote.launcherEnabled": true, "liteNote.clipboardEnabled": true, "liteNote.showInDock": false,
    ])
    shortcuts.onShowNotes = { [weak self] in self?.callback(2, 0, nil) }
    shortcuts.onShowLauncher = { [weak self] in self?.toggle(0) }
    shortcuts.onShowClipboard = { [weak self] in self?.toggle(1) }
    if enabled(1) { clipboard.model.setCaptureEnabled(true) }
    refreshShortcuts()
    applyDock()
    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refreshModifierMonitoring() }
    }
    RunLoop.main.add(timer, forMode: .common)
    permissionTimer = timer
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] _ in
      Task { @MainActor in self?.dismissAfterOutsideClick() }
    }
  }

  func stop() {
    permissionTimer?.invalidate()
    permissionTimer = nil
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    clickMonitor = nil
    if enabled(0) { launcher.hide() }
    if enabled(1) {
      clipboard.hide()
      clipboard.model.setCaptureEnabled(false)
    }
  }

  private func makeLauncher() -> LauncherPanelController {
    let controller = LauncherPanelController()
    controller.onFocusLost = { [weak self] in self?.checkFocus(afterResigning: 0) }
    controller.model.onSearchDocuments = { [weak self] term, request in
      term.withCString { self?.callback(0, request, $0) }
    }
    controller.model.onOpenDocument = { [weak self] document in
      "\(document.window)\n\(document.path)".withCString { self?.callback(1, 0, $0) }
    }
    return controller
  }

  private func makeClipboard() -> ClipboardPanelController {
    let controller = ClipboardPanelController()
    controller.onFocusLost = { [weak self] in self?.checkFocus(afterResigning: 1) }
    return controller
  }

  private func checkFocus(afterResigning panel: Int32) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.enabled(panel) else { return }
      let wasOpen = panel == 0 ? self.launcher.isVisible : self.clipboard.isVisible
      guard wasOpen else { return }
      if self.enabled(0), self.launcher.isVisible, self.launcher.window.isKeyWindow { return }
      if self.enabled(1), self.clipboard.isVisible, self.clipboard.window.isKeyWindow { return }
      self.dismissAfterOutsideClick()
    }
  }

  private func dismissAfterOutsideClick() {
    if enabled(0), launcher.isVisible { launcher.hide() }
    if enabled(1), clipboard.isVisible, shouldDismissPanel(pinned: clipboard.isPinned, peerHasFocus: false) {
      clipboard.hide()
    }
  }

  private func key(_ setting: Int32) -> String {
    switch setting {
    case 0: "liteNote.launcherEnabled"
    case 1: "liteNote.clipboardEnabled"
    default: "liteNote.showInDock"
    }
  }

  func enabled(_ setting: Int32) -> Bool { defaults.bool(forKey: key(setting)) }

  func visible(_ panel: Int32) -> Bool {
    guard enabled(panel) else { return false }
    return panel == 0 ? launcher.isVisible : clipboard.isVisible
  }

  private func refreshShortcuts() {
    let configuration = ShortcutConfiguration(
      launcherModifier: enabled(0) ? .command : nil,
      clipboardShortcut: enabled(1) ? ShortcutChord(modifiers: [.command, .shift], key: "v") : nil)
    do {
      try shortcuts.update(configuration: configuration)
      shortcutError = nil
    } catch {
      shortcutError = error.localizedDescription
      NSLog("Lite Note 快捷键注册失败: %@", error.localizedDescription)
    }
    refreshModifierMonitoring()
  }

  private func refreshModifierMonitoring() {
    if CGPreflightListenEventAccess() {
      if !modifierMonitoring { modifierMonitoring = shortcuts.startModifierMonitoring() }
    } else if modifierMonitoring {
      shortcuts.stopModifierMonitoring()
      modifierMonitoring = false
    }
  }

  private func applyDock() {
    if !NSApp.setActivationPolicy(enabled(2) ? .regular : .accessory) {
      NSLog("Lite Note Dock 显示设置应用失败: %@", enabled(2) ? "显示" : "隐藏")
    }
  }

  func configure(_ setting: Int32, enabled newValue: Bool) {
    defaults.set(newValue, forKey: key(setting))
    switch setting {
    case 0:
      if !newValue { launcher.hide() }
      refreshShortcuts()
    case 1:
      if !newValue { clipboard.hide() }
      clipboard.model.setCaptureEnabled(newValue)
      refreshShortcuts()
    case 2:
      applyDock()
    default:
      break
    }
  }

  func toggle(_ panel: Int32) {
    guard enabled(panel) else { return }
    if panel == 0 {
      switch panelAction(enabled: true, visible: launcher.isVisible) {
      case .show:
        launcher.show()
        if enabled(1), clipboard.isVisible { clipboard.positionOnPointerScreen(avoiding: launcher.window.frame) }
      case .hide: launcher.hide()
      case .none: break
      }
    } else {
      switch panelAction(enabled: true, visible: clipboard.isVisible) {
      case .show: clipboard.show(avoiding: enabled(0) && launcher.isVisible ? launcher.window.frame : nil)
      case .hide: clipboard.hide()
      case .none: break
      }
    }
  }

  func settingsJSON() -> String {
    refreshShortcuts()
    var values: [String: Any] = [
      "launcherEnabled": enabled(0), "clipboardEnabled": enabled(1), "showInDock": enabled(2),
      "inputMonitoring": modifierMonitoring, "accessibility": AXIsProcessTrusted(),
    ]
    if let shortcutError { values["shortcutError"] = shortcutError }
    do {
      return String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)
    } catch {
      NSLog("Lite Note 读取面板设置失败: %@", error.localizedDescription)
      return "{}"
    }
  }

  func receive(_ request: Int64, json: String) {
    guard enabled(0), launcher.isVisible else { return }
    do {
      let response = try JSONDecoder().decode(LauncherDocuments.self, from: Data(json.utf8))
      launcher.model.receiveDocuments(request: request, response: response)
    } catch {
      launcher.model.receiveDocuments(request: request, response: .init(documents: [], error: error.localizedDescription))
    }
  }

  func openedDocument(error: String?) {
    if let error { launcher.model.reportDocumentError(error) } else { launcher.hide() }
  }
}
