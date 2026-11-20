import CoreGraphics
import Foundation

public enum WindowPlacementStrategy: Sendable {
  case nearPointer
  case centered
  case keepCurrentInWorkArea
}

public enum WindowPlacement {
  public static func visibleFrame(
    containing point: CGPoint,
    in visibleFrames: [CGRect]
  ) -> CGRect? {
    visibleFrames.first { frame in
      point.x >= frame.minX && point.x < frame.maxX
        && point.y >= frame.minY && point.y < frame.maxY
    }
  }

  public static func origin(
    current: CGPoint,
    windowSize: CGSize,
    pointer: CGPoint?,
    visibleFrames: [CGRect],
    strategy: WindowPlacementStrategy
  ) -> CGPoint {
    guard
      let pointer,
      let visibleFrame = visibleFrame(containing: pointer, in: visibleFrames)
    else { return current }

    let proposed: CGPoint
    switch strategy {
    case .nearPointer:
      proposed = CGPoint(
        x: pointer.x - windowSize.width / 2,
        y: pointer.y - windowSize.height / 2)
    case .centered:
      proposed = CGPoint(
        x: visibleFrame.midX - windowSize.width / 2,
        y: visibleFrame.midY - windowSize.height / 2)
    case .keepCurrentInWorkArea:
      proposed = current
    }
    return clampedOrigin(proposed, windowSize: windowSize, in: visibleFrame)
  }

  public static func clampedOrigin(
    _ proposed: CGPoint,
    windowSize: CGSize,
    in visibleFrame: CGRect
  ) -> CGPoint {
    let maximumX = max(visibleFrame.minX, visibleFrame.maxX - windowSize.width)
    let maximumY = max(visibleFrame.minY, visibleFrame.maxY - windowSize.height)
    return CGPoint(
      x: min(max(proposed.x, visibleFrame.minX), maximumX),
      y: min(max(proposed.y, visibleFrame.minY), maximumY))
  }
}
