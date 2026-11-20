import Foundation

public enum LauncherApplicationPolicy {
  public static func shouldInclude(
    bundleURL: URL,
    isAgent: Bool,
    isBackgroundOnly: Bool,
    isLaunchProhibited: Bool,
    tags: [String],
    allowsAgentApplication: Bool = false
  ) -> Bool {
    guard !isAgent || allowsAgentApplication, !isBackgroundOnly, !isLaunchProhibited else {
      return false
    }
    guard !tags.contains(where: { $0.caseInsensitiveCompare("hidden") == .orderedSame }) else {
      return false
    }

    let path = bundleURL.standardizedFileURL.path
    let coreServices = "/System/Library/CoreServices/"
    let userFacingCoreServices = "/System/Library/CoreServices/Applications/"
    if path.hasPrefix(coreServices), !path.hasPrefix(userFacingCoreServices) {
      return false
    }
    return true
  }
}
