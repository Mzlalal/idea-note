import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
func requestPanelPermission(_ input: Bool) {
  if input {
    _ = CGRequestListenEventAccess()
  } else {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }
  let anchor = input ? "Privacy_ListenEvent" : "Privacy_Accessibility"
  if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
    NSWorkspace.shared.open(url)
  }
}
