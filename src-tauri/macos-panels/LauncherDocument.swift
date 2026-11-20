import Foundation

struct LauncherDocument: Codable, Equatable {
  let path: String
  let title: String
  let detail: String
  var window: String = "main"

  static func matching(_ documents: [Self], query: String) -> [Self] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return [] }
    return documents.filter { $0.title.localizedCaseInsensitiveContains(term) }
  }
}

struct LauncherDocuments: Decodable {
  let documents: [LauncherDocument]
  let error: String?
}
