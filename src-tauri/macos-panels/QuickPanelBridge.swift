import AppKit
import Darwin

@_cdecl("lite_note_panels_supported")
func liteNotePanelsSupported() -> Bool {
  if #available(macOS 14, *) { return true }
  return false
}

// Tauri marshals every entry point below to the AppKit main thread.
@_cdecl("lite_note_panels_install")
@MainActor
func liteNotePanelsInstall(_ callback: @escaping PanelCallback) {
  if #available(macOS 14, *) { QuickPanels.shared = QuickPanels(callback: callback) }
}

@_cdecl("lite_note_panels_toggle")
@MainActor
func liteNotePanelsToggle(_ panel: Int32) {
  if #available(macOS 14, *) { QuickPanels.shared?.toggle(panel) }
}

@_cdecl("lite_note_panels_settings")
@MainActor
func liteNotePanelsSettings() -> UnsafeMutablePointer<CChar>? {
  if #available(macOS 14, *), let panels = QuickPanels.shared { return strdup(panels.settingsJSON()) }
  return nil
}

@_cdecl("lite_note_panels_configure")
@MainActor
func liteNotePanelsConfigure(_ setting: Int32, _ enabled: Bool) {
  if #available(macOS 14, *) { QuickPanels.shared?.configure(setting, enabled: enabled) }
}

@_cdecl("lite_note_panels_permission")
@MainActor
func liteNotePanelsPermission(_ input: Bool) {
  requestPanelPermission(input)
}

@_cdecl("lite_note_panels_documents")
@MainActor
func liteNotePanelsDocuments(_ request: Int64, _ json: UnsafePointer<CChar>) {
  if #available(macOS 14, *) { QuickPanels.shared?.receive(request, json: String(cString: json)) }
}

@_cdecl("lite_note_panels_opened")
@MainActor
func liteNotePanelsOpened(_ error: UnsafePointer<CChar>?) {
  if #available(macOS 14, *) { QuickPanels.shared?.openedDocument(error: error.map { String(cString: $0) }) }
}
