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
      VStack(alignment: .leading, spacing: 18) {
        Text("chat.sync.title", bundle: .lody).font(.title3.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        if details.phase != .confirmed {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = Int(max(0, (context.date.timeIntervalSince1970 * 1000 - details.since) / 1000))
            Text(String.localizedStringWithFormat(String(localized: "chat.sync.waiting", bundle: .lody), seconds))
              .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
          }
        }
        step(details.document, label: details.history == nil ? "chat.sync.messages" : "chat.sync.sessionState", toComputer: false)
        if let history = details.history { step(history, label: "chat.sync.messages", toComputer: true) }
        if let retry { Button(action: retry) { Text("chat.sync.retry", bundle: .lody) } }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(24)
    }
  }

  private func step(_ step: ConversationSyncDetails.Step, label: String, toComputer: Bool) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(String(localized: String.LocalizationValue(label), bundle: .lody)).font(.subheadline.weight(.semibold))
      let device = String(localized: "chat.sync.device", bundle: .lody)
      let server = String(localized: "chat.sync.server", bundle: .lody)
      let target = machineName.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "chat.sync.target", bundle: .lody)
      let nodes = toComputer ? [device, server, target] : [device, server]
      let request = nodes.joined(separator: " → ")
      Text(String.localizedStringWithFormat(String(localized: "chat.sync.request", bundle: .lody), request))
        .font(.footnote)
      let updates = nodes.reversed().joined(separator: " → ")
      Text(String.localizedStringWithFormat(String(localized: "chat.sync.returnRoute", bundle: .lody), updates))
        .font(.footnote)
      Text(String(localized: String.LocalizationValue("chat.sync." + step.phase.rawValue), bundle: .lody))
        .font(.footnote).foregroundStyle(.secondary)
      if let reason = step.reason {
        Text(String(localized: String.LocalizationValue("chat.sync.reason." + reason), bundle: .lody))
          .font(.footnote).foregroundStyle(.secondary)
      }
    }
  }
}
