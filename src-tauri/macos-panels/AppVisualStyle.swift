import AppKit
import SwiftUI

enum AppVisualStyle {
  static let glassWhiteTintOpacity = 0.12

  #if compiler(>=6.2)
  @available(macOS 26, *)
  static var panelGlass: Glass {
    .regular.tint(.white.opacity(glassWhiteTintOpacity))
  }

  #endif

  @MainActor
  static func configure(scrollView: NSScrollView) {
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.backgroundColor = .clear
    scrollView.verticalScroller?.controlSize = .mini
  }
}

struct AppScrollStyleReader: NSViewRepresentable {
  func makeNSView(context _: Context) -> NSView {
    ScrollStyleProbeView()
  }

  func updateNSView(_ nsView: NSView, context _: Context) {
    (nsView as? ScrollStyleProbeView)?.applyStyle()
  }
}

@MainActor
private final class ScrollStyleProbeView: NSView {
  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    applyStyle()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyStyle()
  }

  override func layout() {
    super.layout()
    applyStyle()
  }

  func applyStyle() {
    guard let scrollView = enclosingScrollView else { return }
    AppVisualStyle.configure(scrollView: scrollView)
  }
}

@available(macOS 14, *)
struct PanelGlass: ViewModifier {
  func body(content: Content) -> some View {
    #if compiler(>=6.2)
    if #available(macOS 26, *) {
      return AnyView(content.glassEffect(AppVisualStyle.panelGlass, in: .rect(cornerRadius: 8)))
    }
    #endif
    return AnyView(content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
      .clipShape(RoundedRectangle(cornerRadius: 8)))
  }
}
