import UIKit

/// Places page-owned icon controls inside the unoccluded part of iOS's vertical-bar
/// strip (for example on iPhone Duo) when system traits and reserved regions confirm
/// safe space. Callers keep their normal header placement whenever `placement(...)`
/// returns `nil`.
enum LodyVerticalBarRail {
  enum Edge: Equatable {
    case left
    case right
  }

  struct Placement: Equatable {
    let frame: CGRect
    let edge: Edge
  }

  struct Environment: Equatable {
    var systemHasVerticalBar: Bool
    var occlusions: [CGRect]
    var divisions: [CGRect] = []
    var keyboardFrame: CGRect = .null
  }

  /// Minimum 44 pt touch target matching `LodySize.touchTarget`.
  static let itemSize: CGFloat = 44
  /// Vertical gap between stacked circular buttons.
  static let spacing: CGFloat = 10
  /// At least 8 pt margin on each horizontal side of a 44 pt button (on Duo's 84 pt bar this leaves 20 pt).
  static let minimumStripWidth: CGFloat = itemSize + 16
  /// Vertical breathing room from system occlusions, divisions, and the keyboard/bottom safe edge.
  static let clearance: CGFloat = 12

  /// Returns the vertical stack frame in `bounds` coordinates, or `nil` when controls must
  /// remain in the ordinary horizontal header.
  static func placement(
    in bounds: CGRect,
    systemHasVerticalBar: Bool,
    safeArea: UIEdgeInsets,
    occlusions: [CGRect],
    divisions: [CGRect] = [],
    keyboardFrame: CGRect = .null,
    itemCount: Int
  ) -> Placement? {
    guard systemHasVerticalBar,
          itemCount > 0,
          bounds.width > 0,
          bounds.height > 0,
          !occlusions.isEmpty else { return nil }

    let leftWidth = min(max(0, safeArea.left), bounds.width)
    let rightWidth = min(max(0, safeArea.right), bounds.width - leftWidth)

    let leftStrip = CGRect(x: bounds.minX, y: bounds.minY, width: leftWidth, height: bounds.height)
    let rightStrip = CGRect(x: bounds.maxX - rightWidth, y: bounds.minY, width: rightWidth, height: bounds.height)

    let leftEligible = leftWidth >= minimumStripWidth && occlusions.contains { $0.intersects(leftStrip) }
    let rightEligible = rightWidth >= minimumStripWidth && occlusions.contains { $0.intersects(rightStrip) }

    let edge: Edge
    let strip: CGRect
    if rightEligible && (!leftEligible || rightWidth >= leftWidth) {
      edge = .right
      strip = rightStrip
    } else if leftEligible {
      edge = .left
      strip = leftStrip
    } else {
      return nil
    }

    let topLimit = bounds.minY + max(0, safeArea.top)
    let bottomLimit = effectiveBottomLimit(in: bounds, safeAreaBottom: max(0, safeArea.bottom), keyboardFrame: keyboardFrame)
    guard bottomLimit > topLimit else { return nil }

    var intervals: [(CGFloat, CGFloat)] = [(topLimit, bottomLimit)]
    for obstruction in occlusions + divisions where obstruction.intersects(strip) {
      let start = max(topLimit, obstruction.minY)
      let end = min(bottomLimit, obstruction.maxY)
      guard end > start else { continue }
      intervals = intervals.flatMap { lo, hi -> [(CGFloat, CGFloat)] in
        if end <= lo || start >= hi { return [(lo, hi)] }
        var remaining: [(CGFloat, CGFloat)] = []
        if start > lo { remaining.append((lo, start)) }
        if end < hi { remaining.append((end, hi)) }
        return remaining
      }
    }

    let needed = CGFloat(itemCount) * itemSize + CGFloat(itemCount - 1) * spacing
    for (lo, hi) in intervals {
      let usableTop = lo + clearance
      let usableBottom = hi - clearance
      if usableBottom - usableTop >= needed {
        let frame = CGRect(
          x: strip.midX - itemSize / 2,
          y: usableTop,
          width: itemSize,
          height: needed
        )
        return Placement(frame: frame, edge: edge)
      }
    }
    return nil
  }

  private static func effectiveBottomLimit(
    in bounds: CGRect,
    safeAreaBottom: CGFloat,
    keyboardFrame: CGRect
  ) -> CGFloat {
    let safeBottom = bounds.maxY - safeAreaBottom
    guard !keyboardFrame.isNull, !keyboardFrame.isEmpty else { return safeBottom }
    let overlap = bounds.intersection(keyboardFrame)
    // Only a docked full/wide keyboard restricts the rail; floating or dismissed guides
    // (which occupy only the bottom safe area) leave the full safe height available.
    guard !overlap.isNull,
          !overlap.isEmpty,
          overlap.maxY >= bounds.maxY - 1,
          overlap.width >= bounds.width * 0.5,
          overlap.height > safeAreaBottom + 1 else { return safeBottom }
    return min(safeBottom, overlap.minY)
  }
}
