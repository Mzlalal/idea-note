import AppKit
import SwiftUI

@available(macOS 14, *)
@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
  let model: ClipboardModel
  private let panel: ClipboardPanel
  private let sourceResolver = SourceApplicationResolver()
  private var applicationObserver: NSObjectProtocol?
  private var keyWindowObserver: NSObjectProtocol?

  override init() {
    model = ClipboardModel.live()
    panel = ClipboardPanel(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 660),
      styleMask: [.resizable, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    super.init()

    model.onDismiss = { [weak self] in self?.hide() }
    model.onPinChange = { [weak self] pinned in self?.applyPinnedLevel(pinned) }
    panel.delegate = self
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.titlebarSeparatorStyle = .none
    panel.isMovableByWindowBackground = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.minSize = NSSize(width: 560, height: 520)
    panel.maxSize = NSSize(width: 920, height: 860)
    panel.collectionBehavior = [.fullScreenAuxiliary]
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    panel.contentViewController = NSHostingController(rootView: ClipboardView(model: model))
    panel.setContentSize(NSSize(width: 680, height: 660))
    panel.setFrameAutosaveName("LiteNote.ClipboardPanel.v3")
    applyPinnedLevel(model.isPinned)
    applicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication
      else { return }
      let bundleIdentifier = application.bundleIdentifier
      Task { @MainActor [weak self] in
        self?.model.updateTargetApplication(bundleIdentifier: bundleIdentifier)
      }
    }
    keyWindowObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let window = notification.object as? NSWindow else { return }
      Task { @MainActor [weak self, weak window] in
        guard let self, let window, !(window is NSPanel), window.isVisible else { return }
        self.model.updateLocalPasteTarget(
          window: window,
          responder: window.firstResponder)
      }
    }
  }

  func show(avoiding peerFrame: NSRect? = nil) {
    let source = sourceResolver.frontmostApplication()
    let localWindow = NSApp.keyWindow.flatMap { window in
      window !== panel && !(window is NSPanel) ? window : nil
    }
    let target = ClipboardPresentationTarget.resolve(
      frontmostBundleIdentifier: source.bundleIdentifier,
      ownBundleIdentifier: Bundle.main.bundleIdentifier,
      hasLocalWindow: localWindow != nil)
    switch target {
    case .local:
      guard let window = localWindow else { break }
      model.updateLocalPasteTarget(window: window, responder: window.firstResponder)
    case .external(let bundleIdentifier):
      model.updateTargetApplication(bundleIdentifier: bundleIdentifier)
    case .unavailable:
      break
    }
    model.prepareForPresentation()
    positionOnPointerScreen(avoiding: peerFrame)
    panel.makeKeyAndOrderFront(nil)
  }

  func hide() {
    panel.orderOut(nil)
  }

  var window: NSPanel { panel }
  var onFocusLost: (() -> Void)?

  var isVisible: Bool { panel.isVisible }
  var isPinned: Bool { model.isPinned }

  func windowDidResignKey(_: Notification) {
    onFocusLost?()
  }

  private func applyPinnedLevel(_ pinned: Bool) {
    panel.level = .floating
    panel.collectionBehavior =
      pinned
      ? [.canJoinAllSpaces, .fullScreenAuxiliary]
      : [.fullScreenAuxiliary, .transient]
  }

  func positionOnPointerScreen(avoiding peerFrame: NSRect?) {
    let pointer = NSEvent.mouseLocation
    let origin = WindowPlacement.origin(
      current: panel.frame.origin,
      windowSize: panel.frame.size,
      pointer: pointer,
      visibleFrames: NSScreen.screens.map(\.visibleFrame),
      strategy: .nearPointer)
    guard let peerFrame,
      let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(pointer) }),
      NSRect(origin: origin, size: panel.frame.size).intersects(peerFrame)
    else {
      panel.setFrameOrigin(origin)
      return
    }
    let bounds = screen.visibleFrame
    let left = peerFrame.minX - panel.frame.width - 12
    let right = peerFrame.maxX + 12
    let x = right + panel.frame.width <= bounds.maxX ? right : max(bounds.minX, left)
    panel.setFrameOrigin(NSPoint(x: x, y: origin.y))
  }
}

private final class ClipboardPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
