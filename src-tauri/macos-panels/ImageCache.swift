import Foundation

public struct CachedImagePaths: Equatable, Sendable {
  public let imagePath: String
  public let thumbnailPath: String

  public init(imagePath: String, thumbnailPath: String) {
    self.imagePath = imagePath
    self.thumbnailPath = thumbnailPath
  }
}

public struct ImageCache: Sendable {
  public static let defaultByteLimit: Int64 = 200 * 1_024 * 1_024

  public let rootURL: URL

  public init(rootURL: URL) {
    let canonicalParent = rootURL.deletingLastPathComponent().resolvingSymlinksInPath()
    self.rootURL =
      canonicalParent
      .appendingPathComponent(rootURL.lastPathComponent, isDirectory: true)
      .standardizedFileURL
  }

  public func store(
    image: Data,
    thumbnail: Data,
    contentHash: String,
    createdAt: Date = Date()
  ) throws -> CachedImagePaths {
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let stem = safeStem(contentHash)
    let imageURL = rootURL.appendingPathComponent("\(stem).image")
    let thumbnailURL = rootURL.appendingPathComponent("\(stem).thumbnail")
    try image.write(to: imageURL, options: .atomic)
    try thumbnail.write(to: thumbnailURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.modificationDate: createdAt], ofItemAtPath: imageURL.path)
    try FileManager.default.setAttributes(
      [.modificationDate: createdAt],
      ofItemAtPath: thumbnailURL.path)
    return CachedImagePaths(imagePath: imageURL.path, thumbnailPath: thumbnailURL.path)
  }

  @discardableResult
  public func cleanup(
    retaining retainedPaths: Set<String>,
    byteLimit: Int64 = defaultByteLimit
  ) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
    let normalizedRetainedPaths = Set(
      retainedPaths.map {
        URL(fileURLWithPath: $0).standardizedFileURL.path
      })
    let resourceKeys: Set<URLResourceKey> = [
      .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
    ]
    let files = try FileManager.default.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: Array(resourceKeys),
      options: [.skipsHiddenFiles])

    var removed: [URL] = []
    var retainedFiles: [CachedFile] = []
    for url in files {
      let values = try url.resourceValues(forKeys: resourceKeys)
      guard values.isRegularFile == true else { continue }
      if !normalizedRetainedPaths.contains(url.standardizedFileURL.path) {
        try FileManager.default.removeItem(at: url)
        removed.append(publicURL(for: url))
      } else {
        retainedFiles.append(
          CachedFile(
            url: url,
            size: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate ?? .distantPast))
      }
    }

    var groups = Dictionary(grouping: retainedFiles) {
      $0.url.deletingPathExtension().lastPathComponent
    }.values.map(Array.init)
    var totalBytes = groups.flatMap { $0 }.reduce(Int64(0)) { $0 + $1.size }
    groups.sort { lhs, rhs in
      (lhs.map(\.modifiedAt).min() ?? .distantPast)
        < (rhs.map(\.modifiedAt).min() ?? .distantPast)
    }

    for group in groups where totalBytes > max(0, byteLimit) {
      for file in group {
        try FileManager.default.removeItem(at: file.url)
        removed.append(publicURL(for: file.url))
        totalBytes -= file.size
      }
    }
    return removed
  }

  private func safeStem(_ contentHash: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let stem = String(contentHash.unicodeScalars.filter(allowed.contains))
    return stem.isEmpty ? UUID().uuidString : stem
  }

  private func publicURL(for fileURL: URL) -> URL {
    rootURL.appendingPathComponent(fileURL.lastPathComponent)
  }
}

private struct CachedFile {
  let url: URL
  let size: Int64
  let modifiedAt: Date
}
