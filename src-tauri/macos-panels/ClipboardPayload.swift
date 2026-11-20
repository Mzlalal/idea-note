import CryptoKit
import Foundation

public enum ClipboardPayload: Equatable, Sendable {
  case text(String)
  case image(Data, thumbnail: Data)
  case files([URL])

  public var kind: ClipboardItemKind {
    switch self {
    case .text: .text
    case .image: .image
    case .files: .files
    }
  }

  public var text: String? {
    guard case .text(let value) = self else { return nil }
    return value
  }

  public var imageData: Data? {
    guard case .image(let data, _) = self else { return nil }
    return data
  }

  public var thumbnailData: Data? {
    guard case .image(_, let thumbnail) = self else { return nil }
    return thumbnail
  }

  public var fileURLs: [URL] {
    guard case .files(let urls) = self else { return [] }
    return urls
  }

  public var contentHash: String {
    var data = Data(kind.rawValue.utf8)
    data.append(0)
    switch self {
    case .text(let text):
      data.append(contentsOf: text.utf8)
    case .image(let image, _):
      data.append(image)
    case .files(let urls):
      let metadata =
        urls
        .map { $0.standardizedFileURL.absoluteString }
        .joined(separator: "\u{0}")
      data.append(contentsOf: metadata.utf8)
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
