import UIKit

extension UIColor {
  static var lodyBackground: UIColor { .systemBackground }
}

#if compiler(>=6.4)
if #available(iOS 27.1, *) {
  let host = LodyFoldHost.make(onLayout: {})
  precondition(host != nil, "The current SDK must enable the Duo fold host")
  let leading = UIViewController()
  let trailing = UIViewController()
  host!.show(leading: leading, trailing: trailing)
  let arrangement = host!.controller as! UIArrangementViewController
  precondition(arrangement.viewController(for: .primary) === leading)
  precondition(arrangement.viewController(for: .secondary) === trailing)
  host!.show(leading: nil, trailing: nil)
  precondition(leading.parent == nil && trailing.parent == nil)
  print("PASS: Duo panes attach to the fold host and detach for layout transitions")
} else {
  precondition(LodyFoldHost.make(onLayout: {}) == nil)
  print("PASS: older runtimes retain the ordinary split")
}

#else
precondition(LodyFoldHost.make(onLayout: {}) == nil)
print("PASS: older SDKs retain the ordinary split")
#endif

// Duo outer display (466 x 678 pt, trailing 84 pt vertical bar, occlusion 84 x 174 pt).
let duoOuter = CGRect(x: 0, y: 0, width: 466, height: 678)
let duoSafe = UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84)
let statusOcclusion = [CGRect(x: 382, y: 0, width: 84, height: 174), CGRect(x: 399.67, y: 29.33, width: 37, height: 37)]

let threeButtons = LodyVerticalBarRail.placement(
  in: duoOuter, systemHasVerticalBar: true, safeArea: duoSafe, occlusions: statusOcclusion, itemCount: 3
)
precondition(threeButtons == LodyVerticalBarRail.Placement(
  frame: CGRect(x: 402, y: 184, width: 44, height: 148), edge: .right
), "Three buttons (Back, Tabs, More) must center in the 84 pt right strip 10 pt below the 174 pt status occlusion")

let twoButtons = LodyVerticalBarRail.placement(
  in: duoOuter, systemHasVerticalBar: true, safeArea: duoSafe, occlusions: statusOcclusion, itemCount: 2
)
precondition(twoButtons == LodyVerticalBarRail.Placement(
  frame: CGRect(x: 402, y: 184, width: 44, height: 96), edge: .right
), "Two buttons must center in the 84 pt right strip 10 pt below the 174 pt status occlusion")

let oneButton = LodyVerticalBarRail.placement(
  in: duoOuter, systemHasVerticalBar: true, safeArea: duoSafe, occlusions: statusOcclusion, itemCount: 1
)
precondition(oneButton == LodyVerticalBarRail.Placement(
  frame: CGRect(x: 402, y: 184, width: 44, height: 44), edge: .right
), "Single button must occupy the same top-aligned slot below status occlusion")

// Docked full-width keyboard (336 pt tall, top at y = 342) leaves y = 184..332 (148 pt): all 3 buttons fit with zero jump.
let dockedKeyboard = CGRect(x: 0, y: 342, width: 466, height: 336)
let withKeyboard = LodyVerticalBarRail.placement(
  in: duoOuter, systemHasVerticalBar: true, safeArea: duoSafe, occlusions: statusOcclusion,
  keyboardFrame: dockedKeyboard, itemCount: 3
)
precondition(withKeyboard == threeButtons, "All three buttons above the docked keyboard must keep the exact same frame")

// Expanded occlusion + keyboard leaving only 62 pt (270..332): 2 buttons fall back, 1 button still fits.
let expandedOcclusion = [CGRect(x: 382, y: 0, width: 84, height: 260)]
precondition(LodyVerticalBarRail.placement(
  in: duoOuter, systemHasVerticalBar: true, safeArea: duoSafe, occlusions: expandedOcclusion,
  keyboardFrame: dockedKeyboard, itemCount: 2
) == nil, "Insufficient space between occlusion and keyboard must fall back to the header")
precondition(LodyVerticalBarRail.placement(
  in: duoOuter, systemHasVerticalBar: true, safeArea: duoSafe, occlusions: expandedOcclusion,
  keyboardFrame: dockedKeyboard, itemCount: 1
) == LodyVerticalBarRail.Placement(frame: CGRect(x: 402, y: 270, width: 44, height: 44), edge: .right))

// Empty occlusions (early mount), disabled vertical bar (iPhone / unfolded portrait), or zero side inset (inspector open) must fall back.
precondition(LodyVerticalBarRail.placement(
  in: duoOuter, systemHasVerticalBar: true, safeArea: duoSafe, occlusions: [], itemCount: 2
) == nil, "Must never draw into the strip before UIKit reports occlusion regions")
precondition(LodyVerticalBarRail.placement(
  in: duoOuter, systemHasVerticalBar: false, safeArea: duoSafe, occlusions: statusOcclusion, itemCount: 2
) == nil, "Must stay in the header when the system has no vertical bar")
precondition(LodyVerticalBarRail.placement(
  in: CGRect(x: 0, y: 0, width: 475.67, height: 669), systemHasVerticalBar: true,
  safeArea: UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0), occlusions: statusOcclusion, itemCount: 2
) == nil, "A leading pane beside an inspector has no vertical-bar inset and must fall back")

// Left-edge vertical bar (RTL or 180-degree rotation).
let leftPlacement = LodyVerticalBarRail.placement(
  in: duoOuter, systemHasVerticalBar: true, safeArea: UIEdgeInsets(top: 0, left: 84, bottom: 34, right: 0),
  occlusions: [CGRect(x: 0, y: 0, width: 84, height: 174)], itemCount: 2
)
precondition(leftPlacement == LodyVerticalBarRail.Placement(
  frame: CGRect(x: 20, y: 184, width: 44, height: 96), edge: .left
), "Left vertical bar must center buttons on the left edge")

// Horizontal division splitting the strip: skip the cramped upper slice and land below the fold.
let horizontalFold = [CGRect(x: 0, y: 260, width: 466, height: 40)]
let belowFold = LodyVerticalBarRail.placement(
  in: duoOuter, systemHasVerticalBar: true, safeArea: duoSafe, occlusions: statusOcclusion,
  divisions: horizontalFold, itemCount: 2
)
precondition(belowFold == LodyVerticalBarRail.Placement(
  frame: CGRect(x: 402, y: 310, width: 44, height: 96), edge: .right
), "A horizontal division must push controls below the fold when the upper slice is too short")

// Floating/undocked keyboard does not collapse the rail.
let floatingKeyboard = CGRect(x: 140, y: 400, width: 180, height: 220)
precondition(LodyVerticalBarRail.placement(
  in: duoOuter, systemHasVerticalBar: true, safeArea: duoSafe, occlusions: statusOcclusion,
  keyboardFrame: floatingKeyboard, itemCount: 2
) == twoButtons, "A floating keyboard must not collapse the vertical bar rail")

// Duo unfolded portrait (669 x 951 pt, safeArea.top = 82 pt, top-right status occlusion 467..669).
let duoPortrait = CGRect(x: 0, y: 0, width: 669, height: 951)
let duoPortraitSafe = UIEdgeInsets(top: 82, left: 0, bottom: 34, right: 0)
let duoPortraitCorner = CGRect(x: 16, y: 82, width: 637, height: 835)
let topRightOcclusion = [CGRect(x: 467, y: 0, width: 202, height: 82)]
let topHeader = LodyVerticalBarRail.topBarHeaderPlacement(
  in: duoPortrait, systemHasVerticalBar: false, safeArea: duoPortraitSafe,
  cornerAdaptedHorizontal: duoPortraitCorner, occlusions: topRightOcclusion
)
precondition(topHeader == CGRect(x: 16, y: 20, width: 441, height: 56),
             "Duo unfolded portrait must lift the 56 pt header into 0..82 beside the top-right status occlusion")

let topLeftOcclusion = [CGRect(x: 0, y: 0, width: 202, height: 82)]
let topHeaderLeft = LodyVerticalBarRail.topBarHeaderPlacement(
  in: duoPortrait, systemHasVerticalBar: false, safeArea: duoPortraitSafe,
  cornerAdaptedHorizontal: duoPortraitCorner, occlusions: topLeftOcclusion
)
precondition(topHeaderLeft == CGRect(x: 212, y: 20, width: 441, height: 56),
             "Duo unfolded portrait with a top-left status occlusion must place the header to its right")

// Ordinary iPhones (Dynamic Island, safeArea.top = 59) and iPads (safeArea.top = 24) stay below safeArea.top.
precondition(LodyVerticalBarRail.topBarHeaderPlacement(
  in: CGRect(x: 0, y: 0, width: 402, height: 874), systemHasVerticalBar: false,
  safeArea: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
  cornerAdaptedHorizontal: CGRect(x: 16, y: 59, width: 370, height: 781),
  occlusions: [CGRect(x: 138, y: 11, width: 126, height: 37)]
) == nil, "Dynamic Island iPhones must never lift the header into safeArea.top")
precondition(LodyVerticalBarRail.topBarHeaderPlacement(
  in: duoOuter, systemHasVerticalBar: true, safeArea: duoPortraitSafe,
  cornerAdaptedHorizontal: duoPortraitCorner, occlusions: topRightOcclusion
) == nil, "Vertical-bar postures must not apply top-bar lifting")

print("PASS: Duo vertical-bar rail and unfolded portrait top-bar placement avoid occlusions, folds and keyboards with clean fallback")
