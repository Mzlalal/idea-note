import Foundation

public struct TransliterationIndex: Equatable, Sendable {
  public let pinyin: String
  public let compactPinyin: String
  public let initials: String

  public init(pinyin: String, compactPinyin: String, initials: String) {
    self.pinyin = pinyin
    self.compactPinyin = compactPinyin
    self.initials = initials
  }
}

public enum Transliterator {
  public static func index(_ text: String) -> TransliterationIndex {
    let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
    let folded = latin.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "zh_CN"))
    let tokens =
      folded
      .lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    return TransliterationIndex(
      pinyin: tokens.joined(separator: " "),
      compactPinyin: tokens.joined(),
      initials: String(tokens.compactMap(\.first)))
  }
}
