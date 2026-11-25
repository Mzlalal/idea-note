import AppKit
import ApplicationServices
import Carbon.HIToolbox

@available(macOS 14, *)
@MainActor
final class ClipboardPasteService {
  var onPasteboardWrite: ((Int) -> Void)?

  private let pasteboard: NSPasteboard

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  @discardableResult
  func paste(
    _ payload: ClipboardPayload,
    into applicationBundleIdentifier: String?,
    releasePanelFocus: () -> Void
  ) -> ClipboardPasteOutcome {
    write(payload)

    let targetApplication = applicationBundleIdentifier.flatMap {
      NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
    }
    let outcome = ClipboardPastePolicy.outcome(
      accessibilityGranted: AXIsProcessTrusted() && CGPreflightPostEventAccess(),
      targetAvailable: targetApplication != nil)
    guard
      outcome == .pasteAndInsert,
      let targetApplication
    else { return .pasteboardOnly }

    releasePanelFocus()
    let pid = targetApplication.processIdentifier
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
      !targetApplication.activate(options: []) { return .pasteboardOnly }

    let changeCount = pasteboard.changeCount
    Task { @MainActor [weak self] in
      for _ in 0..<20 {
        try? await Task.sleep(for: .milliseconds(50))
        guard let self, self.pasteboard.changeCount == changeCount, !targetApplication.isTerminated else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
          Self.postPasteShortcut()
          return
        }
      }
      NSLog("Lite Note clipboard: target process %d did not regain foreground focus", pid)
    }
    return outcome
  }

  func paste(
    _ payload: ClipboardPayload,
    into window: NSWindow,
    restoring responder: NSResponder?
  ) -> ClipboardPasteOutcome {
    write(payload)
    guard window.isVisible, !window.isMiniaturized else { return .pasteboardOnly }
    window.makeKeyAndOrderFront(nil)
    if let responder {
      window.makeFirstResponder(responder)
    }
    let pasted = NSApp.sendAction(#selector(NSText.paste(_:)), to: responder, from: nil)
    return pasted ? .pasteAndInsert : .pasteboardOnly
  }

  private func write(_ payload: ClipboardPayload) {
    pasteboard.clearContents()
    switch payload {
    case .text(let text):
      pasteboard.setString(text, forType: .string)
    case .image(let data, _):
      if let image = NSImage(data: data) {
        pasteboard.writeObjects([image])
      }
    case .files(let urls):
      pasteboard.writeObjects(urls as [NSURL])
    }
    onPasteboardWrite?(pasteboard.changeCount)
  }

  private static func postPasteShortcut() {
    let source = CGEventSource(stateID: .combinedSessionState)
    let keyCode = CGKeyCode(kVK_ANSI_V)
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    keyDown?.flags = .maskCommand
    keyUp?.flags = .maskCommand
    keyDown?.post(tap: .cghidEventTap)
    keyUp?.post(tap: .cghidEventTap)
  }
}
