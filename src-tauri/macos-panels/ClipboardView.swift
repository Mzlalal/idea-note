import SwiftUI

enum ClipboardListIdentity {
  static func rowID(for item: ClipboardItem) -> UUID {
    item.id
  }

  static func scrollTargetID(
    in items: [ClipboardItem],
    selectedIndex: Int?
  ) -> UUID? {
    guard let selectedIndex, items.indices.contains(selectedIndex) else { return nil }
    return items[selectedIndex].id
  }
}

@available(macOS 14, *)
struct ClipboardView: View {
  @ObservedObject var model: ClipboardModel
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("搜索剪贴板", text: $model.query)
          .textFieldStyle(.plain)
          .font(.system(size: 16, weight: .medium))
          .focused($searchFocused)
        Button {
          model.togglePinned()
        } label: {
          Image(systemName: model.isPinned ? "pin.fill" : "pin")
        }
        .buttonStyle(.bordered)
        .help(model.isPinned ? "取消窗口置顶" : "窗口置顶")
      }
      .padding(.horizontal, 16)
      .frame(height: 52)

      Divider()

      if model.displayedItems.isEmpty {
        ContentUnavailableView(
          model.query.isEmpty ? "剪贴板为空" : "没有匹配内容",
          systemImage: model.query.isEmpty ? "clipboard" : "magnifyingglass"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 2) {
              ForEach(Array(model.displayedItems.enumerated()), id: \.element.id) { index, item in
                Button {
                  model.select(index: index)
                  model.pasteSelected()
                } label: {
                  ClipboardRow(
                    item: item,
                    isSelected: index == model.selectedIndex,
                    sourceIcon: model.sourceIcon(for: item),
                    thumbnail: model.thumbnail(for: item),
                    fileThumbnail: model.fileThumbnail(for: item),
                    fileIcon: item.fileURLs.first.flatMap(model.fileIcon(for:)))
                }
                .buttonStyle(.plain)
                .id(ClipboardListIdentity.rowID(for: item))
              }
            }
            .padding(8)
            .background(AppScrollStyleReader())
          }
          .onChange(of: model.selectedIndex) { _, index in
            if let targetID = ClipboardListIdentity.scrollTargetID(
              in: model.displayedItems,
              selectedIndex: index)
            {
              withAnimation(.smooth(duration: 0.16)) {
                proxy.scrollTo(targetID, anchor: .center)
              }
            }
          }
        }
      }
    }
    .modifier(PanelGlass())
    .overlay(alignment: .bottom) {
      if let errorMessage = model.errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(1)
          .padding(.horizontal, 12)
          .frame(height: 30)
          .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 6))
          .padding(10)
      }
    }
    .task(id: model.focusToken) {
      searchFocused = true
    }
    .onKeyPress(.downArrow) {
      model.moveSelection(.down)
      return .handled
    }
    .onKeyPress(.upArrow) {
      model.moveSelection(.up)
      return .handled
    }
    .onKeyPress(.return) {
      model.pasteSelected()
      return .handled
    }
    .onKeyPress(.escape) {
      model.dismissForEscape()
      return .handled
    }
  }
}
