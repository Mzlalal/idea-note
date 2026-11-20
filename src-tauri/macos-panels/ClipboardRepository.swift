import Foundation

func panelStorageDirectory() throws -> URL {
  let support = try FileManager.default.url(
    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
  let identifier = Bundle.main.bundleIdentifier ?? "com.litenote.desktop"
  let directory = support.appendingPathComponent(identifier, isDirectory: true)
    .appendingPathComponent("QuickPanels", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  return directory
}

@MainActor
final class ClipboardRepository {
  private let url: URL

  init(url: URL) {
    self.url = url
  }

  func fetchAll() throws -> [ClipboardItem] {
    do {
      return try JSONDecoder().decode([ClipboardItem].self, from: Data(contentsOf: url))
    } catch let error as NSError where error.domain == NSCocoaErrorDomain
      && error.code == NSFileReadNoSuchFileError {
      return []
    }
  }

  func record(_ item: ClipboardItem) throws {
    var items = try fetchAll()
    items.removeAll { $0.contentHash == item.contentHash }
    items.append(item)
    try save(ClipboardRetention.apply(to: items).retained)
  }

  func delete(ids: [UUID]) throws {
    let removed = Set(ids)
    try save(fetchAll().filter { !removed.contains($0.id) })
  }

  private func save(_ items: [ClipboardItem]) throws {
    try JSONEncoder().encode(items).write(to: url, options: .atomic)
  }
}
