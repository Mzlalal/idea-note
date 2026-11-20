import AppKit
import Foundation

struct WorkspaceApplicationSource: Sendable {
  private static let systemRoots = [
    URL(fileURLWithPath: "/Applications", isDirectory: true),
    URL(fileURLWithPath: "/System/Applications", isDirectory: true),
    URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
  ]

  func scan() async -> [InstalledApplication] {
    await Task.detached(priority: .utility) {
      let userApplications = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications", isDirectory: true)
      return Self.discover(in: Self.systemRoots + [userApplications])
    }.value
  }

  @MainActor
  func icon(for application: InstalledApplication) -> NSImage? {
    guard FileManager.default.fileExists(atPath: application.bundleURL.path) else { return nil }
    return NSWorkspace.shared.icon(forFile: application.bundleURL.path)
  }

  static func isEligible(_ url: URL) -> Bool {
    guard let bundle = Bundle(url: url) else { return false }
    let info = bundle.infoDictionary ?? [:]
    let tags = info["SBAppTags"] as? [String] ?? []
    let isCurrentApplication = bundle.bundleIdentifier == Bundle.main.bundleIdentifier
    return LauncherApplicationPolicy.shouldInclude(
      bundleURL: url,
      isAgent: (info["LSUIElement"] as? NSNumber)?.boolValue == true,
      isBackgroundOnly: (info["LSBackgroundOnly"] as? NSNumber)?.boolValue == true,
      isLaunchProhibited: (info["LSLaunchProhibited"] as? NSNumber)?.boolValue == true,
      tags: tags,
      allowsAgentApplication: isCurrentApplication)
  }

  private static func discover(in roots: [URL]) -> [InstalledApplication] {
    var applicationsByPath: [String: InstalledApplication] = [:]
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]

    for root in roots where FileManager.default.fileExists(atPath: root.path) {
      guard
        let enumerator = FileManager.default.enumerator(
          at: root,
          includingPropertiesForKeys: keys,
          options: [.skipsHiddenFiles, .skipsPackageDescendants])
      else { continue }

      for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
        enumerator.skipDescendants()
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isEligible(canonicalURL), let bundle = Bundle(url: canonicalURL) else {
          continue
        }
        let fallbackName = canonicalURL.deletingPathExtension().lastPathComponent
        let name =
          bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
          ?? bundle.localizedInfoDictionary?["CFBundleName"] as? String
          ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
          ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
          ?? fallbackName
        let index = Transliterator.index(name)
        applicationsByPath[canonicalURL.path.lowercased()] = InstalledApplication(
          name: name,
          bundleIdentifier: bundle.bundleIdentifier,
          bundleURL: canonicalURL,
          pinyin: index.pinyin,
          pinyinInitials: index.initials)
      }
    }

    return applicationsByPath.values.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }
}
