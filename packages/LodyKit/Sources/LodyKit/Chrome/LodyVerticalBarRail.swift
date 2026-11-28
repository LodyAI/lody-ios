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
  /// Vertical gap between stacked circular buttons (matches `pageHeader.spacing`).
  static let spacing: CGFloat = 8
  /// At least 8 pt margin on each horizontal side of a 44 pt button (on Duo's 84 pt bar this leaves 20 pt).
  static let minimumStripWidth: CGFloat = itemSize + 16
  /// Vertical breathing room from system occlusions, divisions, and the keyboard/bottom safe edge.
  /// 10 pt keeps 3 stacked 44 pt buttons (148 pt) clear of both the 174 pt status occlusion and
  /// the 342 pt docked keyboard on iPhone Duo's outer display.
  static let clearance: CGFloat = 10
  /// Height of the conversation page-owned header bar.
  static let topHeaderHeight: CGFloat = 56
  /// Minimum top safe-area height required to lift the header beside a top-corner status occlusion
  /// (iPhone Duo unfolded portrait is 82 pt; Dynamic Island iPhones are ~59–62 pt; iPads are 24 pt).
  static let minimumTopBarHeight: CGFloat = 72
  /// Minimum continuous unoccluded horizontal width needed to host Back/Sidebar, title and actions.
  static let minimumTopHeaderWidth: CGFloat = 240

  /// Returns a frame inside `0 ..< safeArea.top` for `pageHeader` when iOS reserves a tall top
  /// bar (such as iPhone Duo unfolded portrait) with an active corner status occlusion and enough
  /// continuous unoccluded width beside it. Returns `nil` everywhere else so the header remains
  /// below `safeAreaLayoutGuide.topAnchor`.
  static func topBarHeaderPlacement(
    in bounds: CGRect,
    systemHasVerticalBar: Bool,
    safeArea: UIEdgeInsets,
    cornerAdaptedHorizontal: CGRect,
    occlusions: [CGRect]
  ) -> CGRect? {
    guard !systemHasVerticalBar,
          safeArea.top >= minimumTopBarHeight,
          bounds.width > 0,
          bounds.height > 0,
          !occlusions.isEmpty else { return nil }

    let topStrip = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: safeArea.top)
    let topOcclusions = occlusions.filter { $0.intersects(topStrip) }
    guard !topOcclusions.isEmpty else { return nil }

    let cornerMinX = cornerAdaptedHorizontal.isEmpty ? bounds.minX : cornerAdaptedHorizontal.minX
    let cornerMaxX = cornerAdaptedHorizontal.isEmpty ? bounds.maxX : cornerAdaptedHorizontal.maxX
    let leftEdge = max(bounds.minX + safeArea.left + 16, cornerMinX)
    let rightEdge = min(bounds.maxX - safeArea.right - 16, cornerMaxX)
    guard rightEdge > leftEdge else { return nil }

    var intervals: [(CGFloat, CGFloat)] = [(leftEdge, rightEdge)]
    for occ in topOcclusions {
      let start = max(leftEdge, occ.minX - clearance)
      let end = min(rightEdge, occ.maxX + clearance)
      guard end > start else { continue }
      intervals = intervals.flatMap { lo, hi -> [(CGFloat, CGFloat)] in
        if end <= lo || start >= hi { return [(lo, hi)] }
        var remaining: [(CGFloat, CGFloat)] = []
        if start > lo { remaining.append((lo, start)) }
        if end < hi { remaining.append((end, hi)) }
        return remaining
      }
    }

    guard let widest = intervals.max(by: { ($0.1 - $0.0) < ($1.1 - $1.0) }),
          widest.1 - widest.0 >= minimumTopHeaderWidth else { return nil }

    // Align the 56 pt header vertically with the system status indicator (centerY = 48 on Duo's 82 pt bar).
    let y = max(bounds.minY, bounds.minY + safeArea.top - topHeaderHeight - 6)
    return CGRect(x: widest.0, y: y, width: widest.1 - widest.0, height: topHeaderHeight)
  }

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
