import AppKit
import Combine
import QuartzCore
import SwiftUI

@available(macOS 14, *)
@MainActor
final class LauncherPanelController: NSObject, NSWindowDelegate {
  let model: LauncherModel
  private let panel: LauncherPanel
  private var queryObservation: AnyCancellable?
  private var expandedHeight = LauncherPanelLayout.defaultExpandedHeight
  private var isAdjustingFrame = false
  private var frameAnimationGeneration = 0

  override convenience init() {
    self.init(model: LauncherModel.live())
  }

  init(model: LauncherModel) {
    self.model = model
    panel = LauncherPanel(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
      styleMask: [.resizable, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    super.init()

    model.onDismiss = { [weak self] in self?.hide() }
    panel.delegate = self
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.onMoveSelection = { [weak self] direction in
      self?.model.moveSelection(direction)
    }
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.titlebarSeparatorStyle = .none
    panel.isMovableByWindowBackground = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.minSize = NSSize(width: 600, height: LauncherPanelLayout.compactHeight)
    panel.maxSize = NSSize(width: 960, height: 840)
    panel.level = .floating
    panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    panel.contentViewController = NSHostingController(rootView: LauncherView(model: model))
    panel.setContentSize(NSSize(width: 720, height: LauncherPanelLayout.compactHeight))
    panel.setFrameAutosaveName("LiteNote.LauncherPanel.v3")

    queryObservation = model.$query
      .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .removeDuplicates()
      .sink { [weak self] showsResults in
        self?.setResultsVisible(showsResults, animated: self?.panel.isVisible == true)
      }
  }

  func show() {
    model.prepareForPresentation()
    setResultsVisible(false, animated: false)
    positionOnPointerScreen()
    panel.makeKeyAndOrderFront(nil)
  }

  func hide() {
    model.cancelDocumentSearch()
    panel.makeFirstResponder(nil)
    panel.orderOut(nil)
  }

  var window: NSPanel { panel }
  var onFocusLost: (() -> Void)?

  var isVisible: Bool { panel.isVisible }

  func windowDidResignKey(_: Notification) {
    onFocusLost?()
  }

  func windowDidResize(_: Notification) {
    guard !isAdjustingFrame, hasSearchQuery else { return }
    expandedHeight = max(panel.frame.height, LauncherPanelLayout.minimumExpandedHeight)
  }

  private func positionOnPointerScreen() {
    let pointer = NSEvent.mouseLocation
    let placementSize = NSSize(
      width: panel.frame.width,
      height: hasSearchQuery ? panel.frame.height : expandedHeight)
    let expandedOrigin = WindowPlacement.origin(
      current: panel.frame.origin,
      windowSize: placementSize,
      pointer: pointer,
      visibleFrames: NSScreen.screens.map(\.visibleFrame),
      strategy: .centered)
    let origin = CGPoint(
      x: expandedOrigin.x,
      y: expandedOrigin.y + placementSize.height - panel.frame.height)
    panel.setFrameOrigin(origin)
  }

  private var hasSearchQuery: Bool {
    !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func setResultsVisible(_ visible: Bool, animated: Bool) {
    if !visible, !isAdjustingFrame,
      panel.frame.height > LauncherPanelLayout.compactHeight + 1
    {
      expandedHeight = max(panel.frame.height, LauncherPanelLayout.minimumExpandedHeight)
    }

    let targetHeight =
      visible
      ? max(expandedHeight, LauncherPanelLayout.minimumExpandedHeight)
      : LauncherPanelLayout.compactHeight
    let targetMinimumSize = NSSize(
      width: 600,
      height: visible
        ? LauncherPanelLayout.minimumExpandedHeight
        : LauncherPanelLayout.compactHeight)
    if !visible {
      panel.minSize = targetMinimumSize
    }

    frameAnimationGeneration += 1
    let animationGeneration = frameAnimationGeneration
    guard abs(panel.frame.height - targetHeight) > 0.5 else {
      panel.minSize = targetMinimumSize
      isAdjustingFrame = false
      return
    }
    let targetFrame = LauncherPanelLayout.frame(
      keepingTopOf: panel.frame,
      height: targetHeight)
    let shouldAnimate =
      animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    guard shouldAnimate else {
      isAdjustingFrame = false
      panel.setFrame(targetFrame, display: true)
      panel.minSize = targetMinimumSize
      return
    }

    isAdjustingFrame = true
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.24
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().setFrame(targetFrame, display: true)
    } completionHandler: { [weak self] in
      Task { @MainActor in
        guard let self, self.frameAnimationGeneration == animationGeneration else { return }
        self.panel.minSize = targetMinimumSize
        self.isAdjustingFrame = false
      }
    }
  }
}

enum LauncherPanelLayout {
  static let compactHeight: CGFloat = 136
  static let minimumExpandedHeight: CGFloat = 520
  static let defaultExpandedHeight: CGFloat = 620

  static func frame(keepingTopOf frame: CGRect, height: CGFloat) -> CGRect {
    CGRect(
      x: frame.minX,
      y: frame.maxY - height,
      width: frame.width,
      height: height)
  }
}

private final class LauncherPanel: NSPanel {
  var onMoveSelection: ((LauncherSelectionDirection) -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown,
      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
      let direction = Self.selectionDirection(for: event.keyCode)
    {
      onMoveSelection?(direction)
      return
    }
    super.sendEvent(event)
  }

  private static func selectionDirection(for keyCode: UInt16) -> LauncherSelectionDirection? {
    switch keyCode {
    case 125: .down
    case 126: .up
    default: nil
    }
  }
}
