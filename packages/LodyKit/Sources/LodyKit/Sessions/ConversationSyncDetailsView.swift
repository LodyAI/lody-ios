import LodyDesignSystem
import SwiftUI
import UIKit

extension SessionController {
  func makeSyncDetailsView(_ state: SessionFeedState) -> ConversationSyncDetailsView {
    var details = state.syncDetails ?? ConversationSyncDetails(
      since: syncFallbackSince.timeIntervalSince1970 * 1000,
      document: .init(phase: state.status == "live" ? .confirmed : .connecting), history: nil
    )
    let stopped = state.overflow || ["offline", "stopped", "failed"].contains(state.status)
    if stopped && details.phase != .disconnected {
      details = ConversationSyncDetails(
        since: syncFallbackSince.timeIntervalSince1970 * 1000,
        document: .init(phase: .disconnected, reason: state.overflow ? "session_limit" : nil), history: details.history
      )
    }
    let catalog = source.state.catalog
    let machineName = catalog.session(sessionId).flatMap { catalog.machineNames[$0.machineId] }
    return ConversationSyncDetailsView(details: details, machineName: machineName, retry: stopped ? { [weak self] in
      self?.syncDetailsPage?.dismiss(animated: true)
      self?.chat.onReconnect([:])
    } : nil)
  }

  func showSyncDetails() {
    let page = UIHostingController(rootView: makeSyncDetailsView(feed?.state ?? SessionFeedState()))
    page.sheetPresentationController?.detents = [.medium(), .large()]
    page.sheetPresentationController?.prefersGrabberVisible = true
    syncDetailsPage = page
    present(page, animated: true)
  }
}

struct ConversationSyncDetailsView: View {
  let details: ConversationSyncDetails
  let machineName: String?
  let retry: (() -> Void)?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: LodySpacing.lg) {
        Text("chat.sync.title", bundle: .lody).font(.title3.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        if details.phase != .confirmed {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = Int(max(0, (context.date.timeIntervalSince1970 * 1000 - details.since) / 1000))
            Label {
              Text(String.localizedStringWithFormat(String(localized: "chat.sync.waiting", bundle: .lody), seconds))
                .monospacedDigit()
            } icon: {
              Image(systemName: "clock").accessibilityHidden(true)
            }
            .font(.footnote).foregroundStyle(LodyColor.textSecondary)
          }
        }
        step(details.document, label: details.history == nil ? "chat.sync.messages" : "chat.sync.sessionState", toComputer: false)
        if let history = details.history {
          Divider()
          step(history, label: "chat.sync.messages", toComputer: true)
        }
        if let retry { Button(action: retry) { Text("chat.sync.retry", bundle: .lody) } }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(LodySpacing.xxl)
    }
  }

  private func step(_ step: ConversationSyncDetails.Step, label: String, toComputer: Bool) -> some View {
    let phaseColor: Color = switch step.phase {
    case .confirmed: LodyColor.successDefault
    case .retrying, .disconnected: LodyColor.warningDefault
    case .connecting, .syncing: LodyColor.textSecondary
    }
    let phaseIcon: String = switch step.phase {
    case .confirmed: "checkmark"
    case .retrying, .disconnected: "exclamationmark.circle"
    case .connecting, .syncing: "clock"
    }
    let deviceIcon: String = switch UIDevice.current.userInterfaceIdiom {
    case .phone: "iphone"
    case .pad: "ipad"
    case .mac: "laptopcomputer"
    default: "rectangle.on.rectangle"
    }
    let device = SyncNode(icon: deviceIcon, label: String(localized: "chat.sync.device", bundle: .lody))
    let server = SyncNode(icon: "server.rack", label: String(localized: "chat.sync.server", bundle: .lody))
    let target = SyncNode(icon: "desktopcomputer", label: machineName.flatMap { $0.isEmpty ? nil : $0 }
      ?? String(localized: "chat.sync.target", bundle: .lody))

    return VStack(alignment: .leading, spacing: LodySpacing.sm) {
      HStack(alignment: .firstTextBaseline, spacing: LodySpacing.sm) {
        Text(String(localized: String.LocalizationValue(label), bundle: .lody))
          .font(.subheadline.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 0)
        Label {
          Text(String(localized: String.LocalizationValue("chat.sync." + step.phase.rawValue), bundle: .lody))
        } icon: {
          Image(systemName: phaseIcon).foregroundStyle(phaseColor).accessibilityHidden(true)
        }
        .font(.footnote).foregroundStyle(LodyColor.textSecondary)
      }
      flow(source: toComputer ? target : server, relay: toComputer ? server : nil, destination: device)
        .accessibilityIdentifier(toComputer ? "session-sync-history" : "session-sync-document")
      if let reason = step.reason {
        Text(String(localized: String.LocalizationValue("chat.sync.reason." + reason), bundle: .lody))
          .font(.footnote).foregroundStyle(LodyColor.textSecondary)
      }
    }
  }

  private func flow(source: SyncNode, relay: SyncNode?, destination: SyncNode) -> some View {
    let sourceRole = String(localized: "chat.sync.source", bundle: .lody)
    let relayRole = String(localized: "chat.sync.relay", bundle: .lody)
    let receiverRole = String(localized: "chat.sync.destination", bundle: .lody)
    var nodes = [(node: source, role: sourceRole)]
    let description: String
    if let relay {
      nodes.append((relay, relayRole))
      description = String.localizedStringWithFormat(
        String(localized: "chat.sync.relayedFlow", bundle: .lody), source.label, relay.label, destination.label
      )
    } else {
      description = String.localizedStringWithFormat(
        String(localized: "chat.sync.directFlow", bundle: .lody), source.label, destination.label
      )
    }
    nodes.append((destination, receiverRole))

    return HStack(alignment: .top, spacing: 0) {
      ForEach(nodes.indices, id: \.self) { index in
        let (node, role) = nodes[index]
        VStack(spacing: LodySpacing.xs) {
          Image(systemName: node.icon)
            .font(.system(size: LodyIconSize.md))
            .frame(width: LodySize.controlLg, height: LodySize.controlMd)
            .background(LodyColor.bgSunken, in: RoundedRectangle(cornerRadius: LodyRadius.lg))
            .overlay {
              RoundedRectangle(cornerRadius: LodyRadius.lg)
                .strokeBorder(LodyColor.borderSubtle, lineWidth: LodyStroke.default)
            }
          VStack(spacing: LodySpacing.xxs) {
            Text(node.label).font(.footnote).multilineTextAlignment(.center).lineLimit(2)
            Text(role).font(.caption2).foregroundStyle(LodyColor.textSecondary)
          }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
      }
    }
    .overlay(alignment: .topLeading) {
      Canvas { context, size in
        let span = size.width / CGFloat(nodes.count)
        let inset = LodySize.controlLg / 2 + LodySpacing.xs
        let available = span - inset * 2
        guard available > 0 else { return }
        let tip = min(LodySpacing.xs, available / 2)
        let centerY = size.height / 2
        let arrows = Path { path in
          for index in 0..<(nodes.count - 1) {
            let start = (CGFloat(index) + 0.5) * span + inset
            let end = start + available
            path.move(to: CGPoint(x: start, y: centerY))
            path.addLine(to: CGPoint(x: end, y: centerY))
            path.move(to: CGPoint(x: end - tip, y: centerY - tip))
            path.addLine(to: CGPoint(x: end, y: centerY))
            path.addLine(to: CGPoint(x: end - tip, y: centerY + tip))
          }
        }
        context.stroke(arrows, with: .color(LodyColor.accentDefault),
                       style: StrokeStyle(lineWidth: LodyStroke.strong, lineCap: .round, lineJoin: .round))
      }
      .frame(height: LodySize.controlMd)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
    .padding(.vertical, LodySpacing.xs)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: description))
    .accessibilityAddTraits(.isImage)
  }
}

private struct SyncNode {
  let icon: String
  let label: String
}
