import Foundation

public enum ClipboardItemKind: String, Codable, Sendable {
  case text
  case image
  case files
}

public struct ClipboardItem: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var kind: ClipboardItemKind
  public var text: String?
  public var imagePath: String?
  public var thumbnailPath: String?
  public var fileURLs: [URL]
  public var sourceBundleIdentifier: String?
  public var sourceApplicationName: String?
  public var contentHash: String
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    kind: ClipboardItemKind,
    text: String? = nil,
    imagePath: String? = nil,
    thumbnailPath: String? = nil,
    fileURLs: [URL] = [],
    sourceBundleIdentifier: String? = nil,
    sourceApplicationName: String? = nil,
    contentHash: String,
    createdAt: Date
  ) {
    self.id = id
    self.kind = kind
    self.text = text
    self.imagePath = imagePath
    self.thumbnailPath = thumbnailPath
    self.fileURLs = fileURLs
    self.sourceBundleIdentifier = sourceBundleIdentifier
    self.sourceApplicationName = sourceApplicationName
    self.contentHash = contentHash
    self.createdAt = createdAt
  }
}
