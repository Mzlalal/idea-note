import Foundation

public enum LauncherSearch {
  public static func results(
    for query: String,
    in applications: [InstalledApplication],
    limit: Int = 50
  ) -> [InstalledApplication] {
    let uniqueApplications = deduplicated(applications)
    let normalizedQuery = normalized(query)
    guard !normalizedQuery.isEmpty else {
      return
        uniqueApplications
        .filter { $0.lastOpenedAt != nil }
        .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        .prefix(max(0, min(12, limit)))
        .map { $0 }
    }

    return
      uniqueApplications
      .compactMap { application -> (InstalledApplication, Int)? in
        let indexed = indexed(application)
        guard let score = score(query: normalizedQuery, application: indexed) else { return nil }
        return (indexed, score)
      }
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        let leftDate = lhs.0.lastOpenedAt ?? .distantPast
        let rightDate = rhs.0.lastOpenedAt ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
      }
      .prefix(max(0, limit))
      .map(\.0)
  }

  public static func score(query: String, application: InstalledApplication) -> Int? {
    let normalizedQuery = normalized(query)
    guard !normalizedQuery.isEmpty else { return nil }
    let indexed = indexed(application)
    let name = normalized(indexed.name)
    let compactName = compact(name)
    let compactQuery = compact(normalizedQuery)
    let pinyin = normalized(indexed.pinyin)
    let compactPinyin = compact(pinyin)
    let initials = normalized(indexed.pinyinInitials)

    if name == normalizedQuery { return 12_000 }
    if name.hasPrefix(normalizedQuery) { return 10_000 }
    if compactName.hasPrefix(compactQuery) { return 9_500 }
    if name.contains(normalizedQuery) { return 8_000 }
    if compactPinyin.hasPrefix(compactQuery) { return 6_000 }
    if initials.hasPrefix(compactQuery) { return 5_500 }
    if compactPinyin.contains(compactQuery) { return 4_000 }
    if isSubsequence(compactQuery, of: compactName) { return 3_500 }
    if isSubsequence(compactQuery, of: compactPinyin) { return 3_000 }

    let metadata = normalized(
      [indexed.bundleIdentifier, indexed.bundleURL.deletingPathExtension().lastPathComponent]
        .compactMap { $0 }
        .joined(separator: " "))
    return metadata.contains(normalizedQuery) ? 2_500 : nil
  }

  private static func indexed(_ application: InstalledApplication) -> InstalledApplication {
    guard application.pinyin.isEmpty || application.pinyinInitials.isEmpty else {
      return application
    }
    let transliteration = Transliterator.index(application.name)
    var result = application
    result.pinyin = transliteration.pinyin
    result.pinyinInitials = transliteration.initials
    return result
  }

  private static func deduplicated(_ applications: [InstalledApplication]) -> [InstalledApplication]
  {
    var byURL: [String: InstalledApplication] = [:]
    for application in applications {
      let key = application.bundleURL.standardizedFileURL.path.lowercased()
      if let existing = byURL[key] {
        if (application.lastOpenedAt ?? .distantPast) > (existing.lastOpenedAt ?? .distantPast) {
          byURL[key] = application
        }
      } else {
        byURL[key] = application
      }
    }
    return Array(byURL.values)
  }

  private static func normalized(_ value: String) -> String {
    value.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale.current
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .lowercased()
  }

  private static func compact(_ value: String) -> String {
    value.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
  }

  private static func isSubsequence(_ query: String, of candidate: String) -> Bool {
    guard !query.isEmpty else { return false }
    var queryIndex = query.startIndex
    for character in candidate where character == query[queryIndex] {
      query.formIndex(after: &queryIndex)
      if queryIndex == query.endIndex { return true }
    }
    return false
  }
}
