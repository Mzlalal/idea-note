import AppKit

struct SourceApplication: Equatable, Sendable {
  let bundleIdentifier: String?
  let name: String?
}

@MainActor
struct SourceApplicationResolver {
  func frontmostApplication() -> SourceApplication {
    let application = NSWorkspace.shared.frontmostApplication
    return SourceApplication(
      bundleIdentifier: application?.bundleIdentifier,
      name: application?.localizedName)
  }

  func icon(for bundleIdentifier: String?) -> NSImage? {
    guard let bundleIdentifier else { return nil }
    if let icon = NSRunningApplication.runningApplications(
      withBundleIdentifier: bundleIdentifier
    ).first?.icon {
      return icon
    }
    guard
      let applicationURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: bundleIdentifier),
      FileManager.default.fileExists(atPath: applicationURL.path)
    else {
      return nil
    }
    return NSWorkspace.shared.icon(forFile: applicationURL.path)
  }
}
