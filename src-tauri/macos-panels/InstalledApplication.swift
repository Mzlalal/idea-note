import Foundation

public struct InstalledApplication: Codable, Equatable, Identifiable, Sendable {
  public var id: String { bundleURL.path }

  public var name: String
  public var bundleIdentifier: String?
  public var bundleURL: URL
  public var pinyin: String
  public var pinyinInitials: String
  public var lastOpenedAt: Date?

  public init(
    name: String,
    bundleIdentifier: String?,
    bundleURL: URL,
    pinyin: String = "",
    pinyinInitials: String = "",
    lastOpenedAt: Date? = nil
  ) {
    self.name = name
    self.bundleIdentifier = bundleIdentifier
    self.bundleURL = bundleURL
    self.pinyin = pinyin
    self.pinyinInitials = pinyinInitials
    self.lastOpenedAt = lastOpenedAt
  }
}
