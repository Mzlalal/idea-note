import SwiftUI

enum ClipboardTextRowPresentation {
  static func content(_ text: String?) -> String {
    text ?? "空文本"
  }
}

@available(macOS 14, *)
struct ClipboardRow: View {
  let item: ClipboardItem
  let isSelected: Bool
  let sourceIcon: NSImage?
  let thumbnail: NSImage?
  let fileThumbnail: NSImage?
  let fileIcon: NSImage?

  var body: some View {
    HStack(spacing: 12) {
      if let sourceIcon {
        Image(nsImage: sourceIcon)
          .resizable()
          .scaledToFit()
          .frame(width: 30, height: 30)
      }

      rowContent
      Spacer(minLength: 4)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(
      minHeight: ClipboardState.minimumRowHeight,
      maxHeight: ClipboardState.maximumRowHeight
    )
    .background(
      isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
      in: RoundedRectangle(cornerRadius: 6)
    )
    .contentShape(Rectangle())
  }

  @ViewBuilder
  private var rowContent: some View {
    switch item.kind {
    case .text:
      Text(ClipboardTextRowPresentation.content(item.text))
        .font(.system(size: 13))
        .lineLimit(3)
        .multilineTextAlignment(.leading)
    case .image:
      if let thumbnail {
        Image(nsImage: thumbnail)
          .resizable()
          .scaledToFill()
          .frame(width: 62, height: 54)
          .clipShape(RoundedRectangle(cornerRadius: 5))
      }
    case .files:
      if let url = item.fileURLs.first {
        if let fileThumbnail {
          Image(nsImage: fileThumbnail)
            .resizable()
            .scaledToFill()
            .frame(width: 62, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
          if let fileIcon {
            Image(nsImage: fileIcon)
              .resizable()
              .scaledToFit()
              .frame(width: 34, height: 34)
          }
          VStack(alignment: .leading, spacing: 5) {
            if let fileName = ClipboardState.fileName(for: url) {
              Text(fileName)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
            }
            if let path = ClipboardState.filePathSummary(for: url) {
              Text(path)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }
        }
      }
    }
  }
}
