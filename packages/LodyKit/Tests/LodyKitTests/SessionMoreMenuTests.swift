import Foundation
import UIKit
import XCTest
@testable import LodyKit

@MainActor
final class SessionMoreMenuTests: XCTestCase {
  private func localized(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), bundle: .lody)
  }

  private func makeController(
    session: SessionItem,
    extraSessions: [SessionItem] = [],
    layout: StatusViewLayout
  ) -> SessionController {
    let workspaceId = "ws-more-\(UUID().uuidString)"
    let userId = "user-1"
    let catalog = SessionCatalog(
      sessions: [session] + extraSessions,
      statusView: StatusViewLayouts(mine: layout, team: layout, nowMs: 1_700_000_000_000, sectionsLoaded: true)
    )
    let state = SessionListState(
      userId: userId,
      workspaceId: workspaceId,
      workspaces: [AuthWorkspace(id: workspaceId, name: "Workspace", slug: "ws", image: nil)],
      catalog: catalog
    )
    let source = SessionSource(changes: [], read: { state }, write: { _, _, _ in })
    return SessionController(
      sessionId: session.id,
      source: source,
      feed: SessionFeedService(watch: { _, _ in {} }, reconnect: { _ in }, cached: { _, _, _ in nil }),
      previewCache: SessionPreviewCache(observeMemoryWarning: false)
    )
  }

  func testMoreMenuGroupsStatusActionsInSubmenuDirectlyAboveArchive() {
    let opener = SessionItem(id: "opener", title: "Pinned opener", status: "idle", pinned: true)
    let carried = SessionItem(id: "carried", title: "Carried child", status: "idle", pinned: false)
    let layout = StatusViewLayout(
      pinned: [
        StatusViewPinnedSection(
          sectionId: nil,
          name: nil,
          rows: [
            StatusViewRow(
              id: opener.id,
              tier: .pinned,
              children: [StatusViewRow(id: carried.id, tier: .pinned, canManage: true, canPrefer: true)],
              canManage: true,
              canPrefer: true
            ),
          ]
        ),
      ]
    )
    let controller = makeController(session: carried, extraSessions: [opener], layout: layout)
    let elements = controller.moreMenuElements()

    let statusTitle = localized("session.status.title")
    let archiveTitle = localized("session.action.archive")
    let laterTitle = localized("home.status.later")
    let settleTitle = localized("home.status.settle")
    let focusTitle = localized("home.status.moveToFocus")

    let topTitles = elements.map(\.title)
    XCTAssertFalse(topTitles.contains(laterTitle))
    XCTAssertFalse(topTitles.contains(settleTitle))
    XCTAssertFalse(topTitles.contains(focusTitle))

    guard let statusIndex = elements.firstIndex(where: { $0.title == statusTitle }),
          let archiveIndex = elements.firstIndex(where: { $0.title == archiveTitle }) else {
      return XCTFail("Expected both Conversation status submenu and Archive action in More menu: \(topTitles)")
    }
    XCTAssertEqual(statusIndex + 1, archiveIndex, "Conversation status submenu must appear directly above Archive")

    guard let statusSubmenu = elements[statusIndex] as? UIMenu else {
      return XCTFail("Conversation status must be a UIMenu submenu")
    }
    XCTAssertFalse(statusSubmenu.options.contains(.displayInline), "Conversation status must be a secondary submenu, not inline")
    XCTAssertEqual(statusSubmenu.children.map(\.title), [laterTitle, settleTitle, focusTitle])
    XCTAssertTrue(statusSubmenu.children[0] is UIMenu, "Later remains a nested submenu inside Conversation status")
  }

  func testMoreMenuStatusSubmenuFollowsTierAndHidesWhenUnavailable() {
    let statusTitle = localized("session.status.title")
    let laterTitle = localized("home.status.later")
    let settleTitle = localized("home.status.settle")
    let focusTitle = localized("home.status.moveToFocus")

    // Focus tier offers Later and Settle.
    let focusSession = SessionItem(id: "s-focus", title: "Focus", status: "idle")
    let focusController = makeController(
      session: focusSession,
      layout: StatusViewLayout(focus: [StatusViewRow(id: focusSession.id, tier: .focus, canManage: true)])
    )
    let focusStatus = focusController.moreMenuElements().first { $0.title == statusTitle } as? UIMenu
    XCTAssertEqual(focusStatus?.children.map(\.title), [laterTitle, settleTitle])

    // Settled tier offers Later and Move to Focus.
    let settledSession = SessionItem(id: "s-settled", title: "Settled", status: "idle")
    let settledController = makeController(
      session: settledSession,
      layout: StatusViewLayout(settled: [StatusViewRow(id: settledSession.id, tier: .settled, canManage: true)])
    )
    let settledStatus = settledController.moreMenuElements().first { $0.title == statusTitle } as? UIMenu
    XCTAssertEqual(settledStatus?.children.map(\.title), [laterTitle, focusTitle])

    // Archived conversation hides the status submenu.
    let archivedSession = SessionItem(id: "s-archived", title: "Archived", status: "idle", archived: true)
    let archivedController = makeController(
      session: archivedSession,
      layout: StatusViewLayout(focus: [StatusViewRow(id: archivedSession.id, tier: .focus, canManage: true)])
    )
    XCTAssertNil(archivedController.moreMenuElements().first { $0.title == statusTitle })

    // Pinned conversation hides the status submenu.
    let pinnedSession = SessionItem(id: "s-pinned", title: "Pinned", status: "idle", pinned: true)
    let pinnedController = makeController(
      session: pinnedSession,
      layout: StatusViewLayout(pinned: [
        StatusViewPinnedSection(sectionId: nil, name: nil, rows: [
          StatusViewRow(id: pinnedSession.id, tier: .pinned, canManage: true, canPrefer: true),
        ]),
      ])
    )
    XCTAssertNil(pinnedController.moreMenuElements().first { $0.title == statusTitle })

    // Read-only / non-manageable row hides the status submenu.
    let readOnlyController = makeController(
      session: focusSession,
      layout: StatusViewLayout(focus: [StatusViewRow(id: focusSession.id, tier: .focus, canManage: false)])
    )
    XCTAssertNil(readOnlyController.moreMenuElements().first { $0.title == statusTitle })
  }

  func testMoreMenuExposesRemotePreviewSubmenuAfterCopyForPlaintextOpenSessions() throws {
    let session = SessionItem(id: "s-preview", title: "Preview", status: "idle", userId: "user-1", machineId: "linux-box")
    let workspaceId = "ws-remote-preview-\(UUID().uuidString)"
    try WorkspaceModePins.shared.observe(workspaceId, mode: .plaintext)
    let catalog = SessionCatalog(
      sessions: [session],
      machineIds: ["linux-box"],
      machineNames: ["linux-box": "Linux Box"],
      machineOs: ["linux-box": "linux"],
      machineEmulators: ["linux-box": "available"],
      machineCapabilities: ["linux-box": ["previewControl": 1, "androidEmulator": 1]]
    )
    let state = SessionListState(
      userId: "user-1",
      workspaceId: workspaceId,
      workspaces: [AuthWorkspace(id: workspaceId, name: "Workspace", slug: "ws", image: nil)],
      catalog: catalog
    )
    let source = SessionSource(changes: [], read: { state }, write: { _, _, _ in })
    let controller = SessionController(
      sessionId: session.id,
      source: source,
      feed: SessionFeedService(watch: { _, _ in {} }, reconnect: { _ in }, cached: { _, _, _ in nil }),
      previewCache: SessionPreviewCache(observeMemoryWarning: false)
    )

    let elements = controller.moreMenuElements()
    let copyTitle = localized("session.copy.title")
    let remoteTitle = localized("session.remotePreview.title")
    guard let copyIndex = elements.firstIndex(where: { $0.title == copyTitle }),
          let remoteIndex = elements.firstIndex(where: { $0.title == remoteTitle }),
          let remoteSubmenu = elements[remoteIndex] as? UIMenu else {
      return XCTFail("Expected Copy and Remote preview submenus in More menu: \(elements.map(\.title))")
    }
    XCTAssertEqual(copyIndex + 1, remoteIndex, "Remote preview submenu should follow Copy")
    XCTAssertFalse(remoteSubmenu.options.contains(.displayInline))
    XCTAssertEqual(
      remoteSubmenu.children.map(\.title),
      [localized("session.remotePreview.browser"), localized("simulator.menu"), localized("emulator.menu")]
    )
    // Non-macOS keeps iOS Simulator with no extra subtitle text and clickable for the macOS tooltip.
    let iosAction = try XCTUnwrap(remoteSubmenu.children[1] as? UIAction)
    XCTAssertNil(iosAction.subtitle)
    XCTAssertFalse(iosAction.attributes.contains(.disabled))

    // Archived sessions hide the Remote preview submenu.
    let archived = SessionItem(id: "s-arch", title: "Archived", status: "idle", archived: true, userId: "user-1", machineId: "linux-box")
    let archivedState = SessionListState(
      userId: "user-1",
      workspaceId: workspaceId,
      workspaces: state.workspaces,
      catalog: SessionCatalog(sessions: [archived])
    )
    let archivedController = SessionController(
      sessionId: archived.id,
      source: SessionSource(changes: [], read: { archivedState }, write: { _, _, _ in }),
      feed: SessionFeedService(watch: { _, _ in {} }, reconnect: { _ in }, cached: { _, _, _ in nil }),
      previewCache: SessionPreviewCache(observeMemoryWarning: false)
    )
    XCTAssertNil(archivedController.moreMenuElements().first { $0.title == remoteTitle })
  }

  func testRemotePreviewPolicyHandlesMacOSOwnerCapabilityOfflineAndBrowserStates() {
    // Non-macOS computer dims iOS Simulator and reports requiresMacOS on tap.
    XCTAssertTrue(SessionRemotePreview.isIosSimulatorDimmed(machineSimulator: nil))
    XCTAssertEqual(
      SessionRemotePreview.evaluate(
        .iosSimulator,
        sessionUserId: "user-2",
        currentUserId: "user-1",
        machineSimulator: nil,
        machineEmulator: "available",
        machineCapabilities: ["previewControl": 1, "androidEmulator": 1],
        machineOnline: false,
        hasBrowserCandidate: false,
        hasCachedBrowser: false,
        iosRunning: false,
        androidRunning: false
      ),
      .requiresMacOS
    )

    // Non-owner sees items and gets ownerOnly on tap.
    XCTAssertEqual(
      SessionRemotePreview.evaluate(
        .browser,
        sessionUserId: "user-2",
        currentUserId: "user-1",
        machineSimulator: "available",
        machineEmulator: "available",
        machineCapabilities: ["previewControl": 1],
        machineOnline: true,
        hasBrowserCandidate: true,
        hasCachedBrowser: false,
        iosRunning: false,
        androidRunning: false
      ),
      .ownerOnly
    )

    // Old CLI lacking capabilities prompts upgrade instead of hiding.
    XCTAssertEqual(
      SessionRemotePreview.evaluate(
        .iosSimulator,
        sessionUserId: "user-1",
        currentUserId: "user-1",
        machineSimulator: "upgrade-required",
        machineEmulator: nil,
        machineCapabilities: ["previewControl": 1],
        machineOnline: true,
        hasBrowserCandidate: false,
        hasCachedBrowser: false,
        iosRunning: false,
        androidRunning: false
      ),
      .upgradeRequired(.iosSimulator)
    )
    XCTAssertEqual(
      SessionRemotePreview.evaluate(
        .androidEmulator,
        sessionUserId: "user-1",
        currentUserId: "user-1",
        machineSimulator: "available",
        machineEmulator: nil,
        machineCapabilities: ["previewControl": 1],
        machineOnline: true,
        hasBrowserCandidate: false,
        hasCachedBrowser: false,
        iosRunning: false,
        androidRunning: false
      ),
      .upgradeRequired(.androidEmulator)
    )

    // Browser opens when candidate exists, shows empty prompt when absent, and detects stopped server errors.
    XCTAssertEqual(
      SessionRemotePreview.evaluate(
        .browser,
        sessionUserId: "user-1",
        currentUserId: "user-1",
        machineSimulator: "available",
        machineEmulator: "available",
        machineCapabilities: ["previewControl": 1],
        machineOnline: true,
        hasBrowserCandidate: false,
        hasCachedBrowser: false,
        iosRunning: false,
        androidRunning: false
      ),
      .browserEmpty
    )
    XCTAssertEqual(
      SessionRemotePreview.evaluate(
        .browser,
        sessionUserId: "user-1",
        currentUserId: "user-1",
        machineSimulator: "available",
        machineEmulator: "available",
        machineCapabilities: ["previewControl": 1],
        machineOnline: false,
        hasBrowserCandidate: true,
        hasCachedBrowser: false,
        iosRunning: false,
        androidRunning: false
      ),
      .machineOffline
    )
    XCTAssertEqual(
      SessionRemotePreview.evaluate(
        .browser,
        sessionUserId: "user-1",
        currentUserId: "user-1",
        machineSimulator: "available",
        machineEmulator: "available",
        machineCapabilities: ["previewControl": 1],
        machineOnline: false,
        hasBrowserCandidate: true,
        hasCachedBrowser: true,
        iosRunning: false,
        androidRunning: false
      ),
      .openBrowser
    )
    XCTAssertTrue(SessionRemotePreview.isBrowserServerStoppedError("port_not_listening"))
    XCTAssertTrue(SessionRemotePreview.isBrowserServerStoppedError("local_server_unreachable"))
    XCTAssertFalse(SessionRemotePreview.isBrowserServerStoppedError("tunnel_creation_failed"))
  }

  func testSideRailMovesBackTabsAndMoreAndLiftsHeaderInDuoPortrait() throws {
    let root = SessionItem(id: "tab-root", title: "Long conversation title for Duo outer display", status: "idle")
    let sibling = SessionItem(id: "tab-child", title: "Second tab", status: "idle", parentSessionId: root.id)
    let controller = makeController(
      session: root,
      extraSessions: [sibling],
      layout: StatusViewLayout()
    )
    let nav = UINavigationController(rootViewController: UIViewController())
    nav.setNavigationBarHidden(true, animated: false)
    nav.pushViewController(controller, animated: false)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 466, height: 678))
    window.rootViewController = nav
    window.makeKeyAndVisible()
    controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 84)
    nav.view.layoutIfNeeded()
    controller.view.layoutIfNeeded()

    func findView(_ id: String, in root: UIView) -> UIView? {
      if root.accessibilityIdentifier == id { return root }
      for subview in root.subviews {
        if let found = findView(id, in: subview) { return found }
      }
      return nil
    }

    guard let header = findView("chat-page-header", in: controller.view) as? UIStackView,
          let rail = findView("chat-side-rail", in: controller.view) as? UIStackView,
          let back = findView("BackButton", in: controller.view),
          let tabs = findView("chat-directory-tabs", in: controller.view),
          let more = findView("chat-more", in: controller.view) as? UIButton,
          let title = findView("chat-navigation-title", in: controller.view) else {
      return XCTFail("Expected header, side rail, back, tabs, more and title views")
    }

    // Default state (no vertical bar): controls remain in pageHeader and side rail is hidden.
    XCTAssertTrue(rail.isHidden)
    XCTAssertFalse(back.isHidden)
    XCTAssertTrue(header.arrangedSubviews.contains(back))
    XCTAssertTrue(header.arrangedSubviews.contains(tabs))
    XCTAssertTrue(header.arrangedSubviews.contains(more))
    let headerTitleWidth = title.bounds.width

    // Activate vertical-bar side rail on folded outer display through the real viewDidLayoutSubviews -> updateSideRail pipeline.
    let statusOcclusion = [CGRect(x: 382, y: 0, width: 84, height: 174)]
    controller.sideRailEnvironment = {
      LodyVerticalBarRail.Environment(
        systemHasVerticalBar: true,
        occlusions: statusOcclusion,
        keyboardFrame: CGRect(x: 0, y: 342, width: 466, height: 336)
      )
    }
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()

    let expectedFrame = CGRect(x: 402, y: 184, width: 44, height: 148)
    XCTAssertFalse(rail.isHidden)
    XCTAssertEqual(rail.frame, expectedFrame)
    XCTAssertEqual(rail.arrangedSubviews, [back, tabs, more])
    XCTAssertFalse(header.arrangedSubviews.contains(back))
    XCTAssertFalse(header.arrangedSubviews.contains(tabs))
    XCTAssertFalse(header.arrangedSubviews.contains(more))
    XCTAssertGreaterThan(title.bounds.width, headerTitleWidth + 120, "Moving Back, Tabs and More to the side rail must widen the conversation title")

    // More menu anchors via UITargetedPreview inside safeAreaLayoutGuide beside the rail so the right strip stays clear.
    let interaction = try XCTUnwrap(more.contextMenuInteraction)
    let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: nil)
    let preview = try XCTUnwrap(more.contextMenuInteraction(interaction, previewForHighlightingMenuWithConfiguration: config))
    XCTAssertLessThanOrEqual(preview.view.frame.maxX, 382 - 16 + 0.5, "More menu anchor must stay inside safeArea beside the vertical bar")
    XCTAssertEqual(preview.view.frame.minY, 288, accuracy: 0.5, "More menu anchor must align vertically with the More button")

    // VoiceOver order puts pageHeader -> sideRail -> chat.
    let elements = controller.view.accessibilityElements as? [UIView]
    XCTAssertEqual(elements?.prefix(3).map(ObjectIdentifier.init), [
      ObjectIdentifier(header),
      ObjectIdentifier(rail),
      ObjectIdentifier(controller.chat),
    ])

    // Opening ChatTabsOverlay from the right-rail button anchors the card beside the rail inside the safe area.
    let overlay = ChatTabsOverlay.present(
      ChatTabsPanel(
        state: ChatTabsState(
          tabs: [
            ChatTabItem(id: root.id, title: root.title, attention: nil, current: true),
            ChatTabItem(id: sibling.id, title: sibling.title, attention: nil, current: false),
          ],
          closed: []
        ),
        onSelect: { _ in }, onClose: { _ in }, onRestore: { _ in }
      ),
      tabs: 2,
      in: controller,
      source: tabs
    )
    controller.view.layoutIfNeeded()
    let cardFrame = overlay.subviews.first!.frame
    XCTAssertLessThanOrEqual(cardFrame.maxX, 382 - 16 + 0.5, "Tabs card must remain inside the safe area beside the vertical bar")
    XCTAssertGreaterThanOrEqual(cardFrame.minY, 230, "Tabs card must anchor vertically near the side-rail Tabs button")
    overlay.removeFromSuperview()

    // Unfolded Duo portrait (669 x 951, safeArea.top = 82, top-right status occlusion):
    // side rail falls back to canonical header order AND pageHeader lifts into 0..82 beside the status indicator.
    window.frame = CGRect(x: 0, y: 0, width: 669, height: 951)
    controller.additionalSafeAreaInsets = UIEdgeInsets(top: 82, left: 0, bottom: 34, right: 0)
    controller.sideRailEnvironment = {
      LodyVerticalBarRail.Environment(
        systemHasVerticalBar: false,
        occlusions: [CGRect(x: 467, y: 0, width: 202, height: 82)]
      )
    }
    nav.view.layoutIfNeeded()
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()

    XCTAssertTrue(rail.isHidden)
    XCTAssertEqual(header.arrangedSubviews.suffix(4), [back, title, tabs, more])
    XCTAssertEqual(header.frame.minY, 20, accuracy: 0.5, "Unfolded Duo portrait must lift pageHeader into 0..82 aligned with the status bar")
    XCTAssertLessThanOrEqual(header.frame.maxX, 457.5, "Lifted pageHeader must clear the top-right status occlusion")
    XCTAssertTrue(controller.chat.pageHeaderSitsInTopSafeArea)
    XCTAssertEqual(controller.chat.pageHeaderHeight, 0)
    XCTAssertNil(controller.view.accessibilityElements)

    // Opening ChatTabsOverlay from the lifted top-bar Tabs button anchors under the lifted header, not under the status bar.
    let portraitOverlay = ChatTabsOverlay.present(
      ChatTabsPanel(
        state: ChatTabsState(
          tabs: [
            ChatTabItem(id: root.id, title: root.title, attention: nil, current: true),
            ChatTabItem(id: sibling.id, title: sibling.title, attention: nil, current: false),
          ],
          closed: []
        ),
        onSelect: { _ in }, onClose: { _ in }, onRestore: { _ in }
      ),
      tabs: 2,
      in: controller,
      source: tabs
    )
    controller.view.layoutIfNeeded()
    let portraitCardFrame = portraitOverlay.subviews.first!.frame
    XCTAssertGreaterThanOrEqual(portraitCardFrame.minY, 82, "Tabs card must open below the lifted top bar")
    XCTAssertLessThanOrEqual(portraitCardFrame.maxX, 467, "Tabs card must align under the lifted header rather than the status bar")
    portraitOverlay.removeFromSuperview()

    // Ordinary iPhone fallback (safeArea.top = 59, no vertical bar) restores pageHeader below safeArea.top.
    window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
    controller.additionalSafeAreaInsets = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
    controller.sideRailEnvironment = {
      LodyVerticalBarRail.Environment(systemHasVerticalBar: false, occlusions: [])
    }
    nav.view.layoutIfNeeded()
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()

    XCTAssertFalse(controller.chat.pageHeaderSitsInTopSafeArea)
    XCTAssertEqual(controller.chat.pageHeaderHeight, 56)
    XCTAssertEqual(header.frame.minY, 59, accuracy: 0.5)
  }
}
