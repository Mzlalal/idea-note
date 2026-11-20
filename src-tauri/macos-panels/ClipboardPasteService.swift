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
    into applicationBundleIdentifier: String?
  ) -> ClipboardPasteOutcome {
    write(payload)

    let targetApplication = applicationBundleIdentifier.flatMap {
      NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
    }
    let outcome = ClipboardPastePolicy.outcome(
      accessibilityGranted: AXIsProcessTrusted(),
      targetAvailable: targetApplication != nil)
    guard
      outcome == .pasteAndInsert,
      let targetApplication,
      targetApplication.activate(options: [])
    else { return .pasteboardOnly }

    let expectedBundleIdentifier = targetApplication.bundleIdentifier
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(80))
      guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == expectedBundleIdentifier
      else { return }
      Self.postPasteShortcut()
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
