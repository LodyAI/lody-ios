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
        Divider()
        HStack(spacing: LodySpacing.lg) {
          Label { Text("chat.sync.request", bundle: .lody) } icon: {
            Image(systemName: "arrow.right").foregroundStyle(LodyColor.accentDefault)
          }
          Label { Text("chat.sync.returnRoute", bundle: .lody) } icon: {
            Image(systemName: "arrow.left")
          }
        }
        .font(.footnote)
        .foregroundStyle(LodyColor.textSecondary)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
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
    let device = SyncNode(icon: "iphone", label: String(localized: "chat.sync.device", bundle: .lody))
    let server = SyncNode(icon: "server.rack", label: String(localized: "chat.sync.server", bundle: .lody))
    let target = SyncNode(icon: "desktopcomputer", label: machineName.flatMap { $0.isEmpty ? nil : $0 }
      ?? String(localized: "chat.sync.target", bundle: .lody))
    let nodes = toComputer ? [device, server, target] : [device, server]

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
      flow(nodes)
        .accessibilityIdentifier(toComputer ? "session-sync-history" : "session-sync-document")
      if let reason = step.reason {
        Text(String(localized: String.LocalizationValue("chat.sync.reason." + reason), bundle: .lody))
          .font(.footnote).foregroundStyle(LodyColor.textSecondary)
      }
    }
  }

  private func flow(_ nodes: [SyncNode]) -> some View {
    let labels = nodes.map(\.label)
    let request = String(localized: "chat.sync.request", bundle: .lody)
    let returns = String(localized: "chat.sync.returnRoute", bundle: .lody)
    return HStack(alignment: .top, spacing: 0) {
      ForEach(nodes, id: \.icon) { node in
        if node.icon != nodes.first?.icon { flowLink }
        VStack(spacing: LodySpacing.xs) {
          Image(systemName: node.icon)
            .font(.system(size: LodyIconSize.md))
            .frame(width: LodySize.controlLg, height: LodySize.controlMd)
            .background(LodyColor.bgSunken, in: RoundedRectangle(cornerRadius: LodyRadius.lg))
            .overlay {
              RoundedRectangle(cornerRadius: LodyRadius.lg)
                .strokeBorder(LodyColor.borderSubtle, lineWidth: LodyStroke.default)
            }
          Text(node.label).font(.footnote).multilineTextAlignment(.center).lineLimit(2)
        }
        .frame(maxWidth: .infinity)
      }
    }
    .padding(.vertical, LodySpacing.xs)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: "\(request) \(labels.joined(separator: " → ")). \(returns) \(labels.reversed().joined(separator: " → "))."))
    .accessibilityAddTraits(.isImage)
  }

  private var flowLink: some View {
    Canvas { context, size in
      let tip = LodySpacing.xs
      let upper = size.height / 2 - LodySpacing.xs
      let lower = size.height / 2 + LodySpacing.xs
      let leading = LodySpacing.xxs
      let trailing = size.width - LodySpacing.xxs
      let stroke = StrokeStyle(lineWidth: LodyStroke.strong, lineCap: .round, lineJoin: .round)
      let request = Path { path in
        path.move(to: CGPoint(x: leading, y: upper))
        path.addLine(to: CGPoint(x: trailing, y: upper))
        path.move(to: CGPoint(x: trailing - tip, y: upper - tip))
        path.addLine(to: CGPoint(x: trailing, y: upper))
        path.addLine(to: CGPoint(x: trailing - tip, y: upper + tip))
      }
      let update = Path { path in
        path.move(to: CGPoint(x: trailing, y: lower))
        path.addLine(to: CGPoint(x: leading, y: lower))
      }
      let updateTip = Path { path in
        path.move(to: CGPoint(x: leading + tip, y: lower - tip))
        path.addLine(to: CGPoint(x: leading, y: lower))
        path.addLine(to: CGPoint(x: leading + tip, y: lower + tip))
      }
      context.stroke(request, with: .color(LodyColor.accentDefault), style: stroke)
      context.stroke(update, with: .color(LodyColor.textSecondary), style: StrokeStyle(lineWidth: LodyStroke.default, dash: [tip, tip]))
      context.stroke(updateTip, with: .color(LodyColor.textSecondary), style: stroke)
    }
    .frame(minWidth: LodySize.controlXs, maxWidth: LodySize.controlLg)
    .frame(height: LodySize.controlMd)
    .accessibilityHidden(true)
  }
}

private struct SyncNode {
  let icon: String
  let label: String
}
