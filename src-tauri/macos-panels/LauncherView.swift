import SwiftUI

enum LauncherListIdentity {
  static func rowID(for application: InstalledApplication) -> String {
    application.id
  }

  static func scrollTargetID(
    in applications: [InstalledApplication],
    selectedIndex: Int?
  ) -> String? {
    guard let selectedIndex, applications.indices.contains(selectedIndex) else { return nil }
    return applications[selectedIndex].id
  }
}

@available(macOS 14, *)
struct LauncherView: View {
  @ObservedObject var model: LauncherModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(.secondary)
        TextField("搜索应用或文档", text: $model.query)
          .textFieldStyle(.plain)
          .font(.system(size: 18, weight: .medium))
          .focused($searchFocused)
        if !model.query.isEmpty {
          Button {
            model.query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help("清除搜索")
        }
      }
      .padding(.horizontal, 18)
      .frame(height: 58)

      Divider()

      recentContent

      if hasSearchQuery {
        Divider()
        HStack(spacing: 0) {
          resultColumn("应用") { searchResults }
          Divider()
          resultColumn("文档") { documentResults }
        }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .transition(
            reduceMotion
              ? .identity
              : .opacity.combined(with: .move(edge: .top)))
      }

      if hasSearchQuery, let errorMessage = model.errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(1)
          .padding(.horizontal, 16)
          .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
          .background(.bar)
      }
    }
    .modifier(PanelGlass())
    .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: hasSearchQuery)
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
      model.activateSelected()
      return .handled
    }
    .onKeyPress(.escape) {
      model.dismiss()
      return .handled
    }
  }

  private func resultColumn<Content: View>(
    _ title: LocalizedStringKey, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private var documentResults: some View {
    if let error = model.documentError {
      Text(error).foregroundStyle(.secondary).padding()
    } else if model.isSearchingDocuments {
      ProgressView().controlSize(.small)
    } else if model.documents.isEmpty {
      ContentUnavailableView("没有找到文档", systemImage: "doc.text.magnifyingglass")
    } else {
      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(model.documents, id: \.path) { document in
            Button {
              model.onOpenDocument?(document)
            } label: {
              HStack(spacing: 10) {
                Image(systemName: "doc.text")
                  .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                  Text(document.title).lineLimit(1)
                  Text(document.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
              }
              .padding(8)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(document.detail)
          }
        }
        .padding(.horizontal, 8)
      }
    }
  }

  private var hasSearchQuery: Bool {
    !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var recentRow: some View {
    HStack(spacing: 4) {
      ForEach(Array(model.recentApplications.enumerated()), id: \.element.id) { index, app in
        let isSelected = !hasSearchQuery && index == model.selectedIndex
        ZStack(alignment: .topTrailing) {
          Button {
            if !hasSearchQuery {
              model.select(index: index)
            }
            model.activate(app)
          } label: {
            Group {
              if let icon = model.icon(for: app) {
                Image(nsImage: icon)
                  .resizable()
                  .scaledToFit()
                  .frame(width: 44, height: 44)
              }
            }
            .frame(width: 50, height: 60)
            .contentShape(Rectangle())
            .background(
              isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
              in: RoundedRectangle(cornerRadius: 7))
          }
          .buttonStyle(.plain)
          .help(app.name)

          Button {
            model.removeFromRecent(app)
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.secondary)
              .frame(width: 20, height: 20)
          }
          .buttonStyle(.plain)
          .help("从最近使用中移除")
          .opacity(model.hoveredRecentID == app.id || isSelected ? 1 : 0)
          .allowsHitTesting(model.hoveredRecentID == app.id || isSelected)
        }
        .onHover { hovering in
          model.hoveredRecentID = hovering ? app.id : nil
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .frame(height: 76)
  }

  @ViewBuilder
  private var recentContent: some View {
    if !model.recentApplications.isEmpty {
      recentRow
    } else if model.isLoading {
      HStack(spacing: 10) {
        ProgressView()
          .controlSize(.small)
        Text("正在读取最近使用的应用")
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(.horizontal, 18)
      .frame(height: 76)
    } else {
      HStack(spacing: 10) {
        Image(systemName: "clock")
          .foregroundStyle(.secondary)
        Text("还没有最近使用的应用")
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(.horizontal, 18)
      .frame(height: 76)
    }
  }

  @ViewBuilder
  private var searchResults: some View {
    if model.isLoading, model.displayedApplications.isEmpty {
      launcherLoading
    } else if model.displayedApplications.isEmpty {
      ContentUnavailableView("没有找到应用", systemImage: "app.dashed")
    } else {
      resultsList
    }
  }

  private var resultsList: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(Array(model.displayedApplications.enumerated()), id: \.element.id) { index, app in
            Button {
              model.select(index: index)
              model.activate(app)
            } label: {
              HStack(spacing: 12) {
                if let icon = model.icon(for: app) {
                  Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                }
                Text(app.name)
                  .font(.system(size: 13.5, weight: .semibold))
                Spacer()
              }
              .padding(.horizontal, 12)
              .frame(height: 52)
              .background(
                index == model.selectedIndex ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
              )
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(LauncherListIdentity.rowID(for: app))
          }
        }
        .padding(8)
        .background(AppScrollStyleReader())
      }
      .onChange(of: model.selectedIndex) { _, index in
        if let targetID = LauncherListIdentity.scrollTargetID(
          in: model.displayedApplications,
          selectedIndex: index)
        {
          withAnimation(.smooth(duration: 0.16)) {
            proxy.scrollTo(targetID, anchor: .center)
          }
        }
      }
    }
  }

  private var launcherLoading: some View {
    VStack(spacing: 12) {
      ForEach(0..<4, id: \.self) { _ in
        RoundedRectangle(cornerRadius: 6)
          .fill(.quaternary)
          .frame(height: 48)
      }
    }
    .padding(16)
  }
}
