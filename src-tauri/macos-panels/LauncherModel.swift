import AppKit
import Combine
import Foundation

@available(macOS 14, *)
@MainActor
final class LauncherModel: ObservableObject {
  @Published var query = "" {
    didSet {
      updateResults()
      searchDocuments()
    }
  }
  @Published private(set) var applications: [InstalledApplication] = []
  @Published private(set) var displayedApplications: [InstalledApplication] = []
  @Published private(set) var selectedIndex: Int?
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?
  @Published private(set) var focusToken = 0

  @Published var hoveredRecentID: String?

  @Published private(set) var documents: [LauncherDocument] = []
  @Published private(set) var documentError: String?
  @Published private(set) var isSearchingDocuments = false
  var onSearchDocuments: ((String, Int64) -> Void)?
  var onOpenDocument: ((LauncherDocument) -> Void)?
  private var documentRequest: Int64 = 0
  private var documentSearchTask: Task<Void, Never>?

  private func searchDocuments() {
    documentRequest += 1
    documentSearchTask?.cancel()
    documents = []
    documentError = nil
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    isSearchingDocuments = !term.isEmpty && onSearchDocuments != nil
    guard isSearchingDocuments else { return }
    let request = documentRequest
    documentSearchTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      self?.onSearchDocuments?(term, request)
    }
  }

  func receiveDocuments(request: Int64, response: LauncherDocuments) {
    guard request == documentRequest else { return }
    documents = LauncherDocument.matching(response.documents, query: query)
    documentError = response.error
    isSearchingDocuments = false
  }

  func reportDocumentError(_ error: String) {
    documentError = error
  }

  func cancelDocumentSearch() {
    documentSearchTask?.cancel()
    documentRequest += 1
    isSearchingDocuments = false
  }

  var onDismiss: (() -> Void)?

  private let source = WorkspaceApplicationSource()
  private let scanApplications: @MainActor () async -> [InstalledApplication]
  private let cacheURL: URL?
  private let iconCache = NSCache<NSString, NSImage>()
  private var state = LauncherState()
  private var retryCount = 0
  private var retryTask: Task<Void, Never>?

  var mode: LauncherMode { state.mode }

  var recentApplications: [InstalledApplication] {
    LauncherSearch.results(
      for: "",
      in: applications,
      limit: LauncherState.recentLimit)
  }

  var selectedApplication: InstalledApplication? {
    guard let selectedIndex, displayedApplications.indices.contains(selectedIndex) else {
      return nil
    }
    return displayedApplications[selectedIndex]
  }

  static func live() -> LauncherModel {
    do {
      let root = try panelStorageDirectory()
      return LauncherModel(cacheURL: root.appendingPathComponent("launcher-applications.json"))
    } catch {
      return LauncherModel(cacheURL: nil, errorMessage: error.localizedDescription)
    }
  }

  init(
    cacheURL: URL?,
    errorMessage: String? = nil,
    scanApplications: @escaping @MainActor () async -> [InstalledApplication] = {
      await WorkspaceApplicationSource().scan()
    }
  ) {
    self.cacheURL = cacheURL
    self.errorMessage = errorMessage
    self.scanApplications = scanApplications
    applications = Self.loadCache(from: cacheURL)
    updateResults()
  }

  func prepareForPresentation() {
    query = ""
    focusToken += 1
    loadApplications()
  }

  func loadApplications() {
    guard !isLoading else { return }
    retryTask?.cancel()
    retryTask = nil
    isLoading = true
    Task {
      let discovered = await scanApplications()
      guard !discovered.isEmpty else {
        isLoading = false
        errorMessage =
          applications.isEmpty
          ? "没有扫描到可用应用，稍后会自动重试"
          : "应用索引刷新失败，正在使用上次结果"
        updateResults()
        scheduleRetry()
        return
      }

      var loadError: String?
      let recentDates = Dictionary(
        applications.compactMap { app in
          app.lastOpenedAt.map { (app.bundleURL.standardizedFileURL.path.lowercased(), $0) }
        }, uniquingKeysWith: max)

      let selectedApplicationID = selectedApplication?.id
      applications = discovered.map { application in
        var application = application
        application.lastOpenedAt =
          recentDates[application.bundleURL.standardizedFileURL.path.lowercased()]
        return application
      }
      do {
        try saveCache(applications)
      } catch {
        loadError = loadError ?? "无法保存应用索引：\(error.localizedDescription)"
      }
      retryCount = 0
      isLoading = false
      errorMessage = loadError
      updateResults(preservingSelectionID: selectedApplicationID)
    }
  }

  func moveSelection(_ direction: LauncherSelectionDirection) {
    state.moveSelection(direction)
    selectedIndex = state.selectedIndex
  }

  func select(index: Int) {
    guard displayedApplications.indices.contains(index) else { return }
    state.select(index: index)
    selectedIndex = state.selectedIndex
  }

  func activateSelected() {
    guard let application = selectedApplication else { return }
    activate(application)
  }

  func activate(_ application: InstalledApplication) {
    guard FileManager.default.fileExists(atPath: application.bundleURL.path) else {
      errorMessage = "应用已被移动或删除"
      applications.removeAll { $0.id == application.id }
      updateResults()
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(
      at: application.bundleURL,
      configuration: configuration
    ) { [weak self] _, error in
      Task { @MainActor in
        guard let self else { return }
        if let error {
          self.errorMessage = error.localizedDescription
          return
        }
        do {
          let openedAt = Date()
          if let index = self.applications.firstIndex(where: { $0.id == application.id }) {
            self.applications[index].lastOpenedAt = openedAt
            try self.saveCache(self.applications)
          }
        } catch {
          self.errorMessage = error.localizedDescription
        }
        self.onDismiss?()
      }
    }
  }

  func removeFromRecent(_ application: InstalledApplication) {
    do {
      if let index = applications.firstIndex(where: { $0.id == application.id }) {
        applications[index].lastOpenedAt = nil
      }
      try saveCache(applications)
      errorMessage = nil
      updateResults()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func dismiss() {
    onDismiss?()
  }

  func icon(for application: InstalledApplication) -> NSImage? {
    let key = application.bundleURL.path as NSString
    if let cached = iconCache.object(forKey: key) {
      return cached
    }
    guard let icon = source.icon(for: application) else { return nil }
    iconCache.setObject(icon, forKey: key)
    return icon
  }

  private func updateResults(preservingSelectionID: String? = nil) {
    var results = LauncherSearch.results(for: query, in: applications, limit: 50)
    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, results.isEmpty {
      results = Array(applications.prefix(LauncherState.recentLimit))
    }
    displayedApplications = results
    state.update(query: query, availableCount: results.count)
    if let preservingSelectionID,
      let preservedIndex = results.firstIndex(where: { $0.id == preservingSelectionID })
    {
      state.select(index: preservedIndex)
    }
    selectedIndex = state.selectedIndex
  }

  private func scheduleRetry() {
    retryCount += 1
    guard retryCount <= 3 else { return }
    let delay = min(30, 1 << retryCount)
    retryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.loadApplications()
    }
  }

  private func saveCache(_ applications: [InstalledApplication]) throws {
    guard let cacheURL else { return }
    let data = try JSONEncoder().encode(applications)
    try data.write(to: cacheURL, options: .atomic)
  }

  private static func loadCache(from cacheURL: URL?) -> [InstalledApplication] {
    guard
      let cacheURL,
      let data = try? Data(contentsOf: cacheURL),
      let cached = try? JSONDecoder().decode([InstalledApplication].self, from: data)
    else { return [] }
    return cached.filter {
      FileManager.default.fileExists(atPath: $0.bundleURL.path)
        && WorkspaceApplicationSource.isEligible($0.bundleURL)
    }
  }
}
