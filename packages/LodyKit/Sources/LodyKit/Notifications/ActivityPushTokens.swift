@preconcurrency import ActivityKit
import Foundation
import UIKit

/// Direct APNs has separate device, push-to-start, and per-activity tokens.
@MainActor
final class ActivityPushTokens {
  private typealias Live = Activity<LodyConversationLiveActivityAttributes>
  private let sync = ActivityTokenSync()
  private var observers: [Task<Void, Never>] = []
  private var updates: [String: Task<Void, Never>] = [:]

  func reconcile(
    provider: PushRegistration.Provider?,
    authorized: Bool,
    registered: Bool,
    session: PushRegistration.Session?,
    registrationEpoch: Int
  ) {
    let action = sync.transition(
      provider: provider,
      authorized: authorized,
      registered: registered,
      session: session,
      registrationEpoch: registrationEpoch
    )
    switch action {
    case .unchanged:
      return
    case .stop:
      cancelAll()
    case .start(let target):
      cancelAll()
      // ActivityKit tokens only exist where Live Activities can run.
      guard ConversationActivities.supported else { return }
      for activity in Live.activities { observe(activity, target: target) }
      observers.append(Task {
        for await activity in Live.activityUpdates {
          guard !Task.isCancelled else { return }
          observe(activity, target: target)
        }
      })
      if #available(iOS 17.2, *) {
        observers.append(Task {
          if let token = Live.pushToStartToken { await upload(token, target: target) }
          for await token in Live.pushToStartTokenUpdates {
            guard !Task.isCancelled else { return }
            await upload(token, target: target)
          }
        })
      }
    }
  }

  private func cancelAll() {
    observers.forEach { $0.cancel() }
    updates.values.forEach { $0.cancel() }
    observers.removeAll()
    updates.removeAll()
  }

  private func observe(_ activity: Live, target: ActivityTokenSync.Target) {
    let attributes = activity.attributes
    guard attributes.activityId == "lody-conversations:v5:\(attributes.workspaceId):\(target.session.user)",
          updates[activity.id] == nil else { return }
    updates[activity.id] = Task {
      if let token = activity.pushToken { await upload(token, target: target, activity: activity) }
      for await token in activity.pushTokenUpdates {
        guard !Task.isCancelled else { return }
        await upload(token, target: target, activity: activity)
      }
      if !Task.isCancelled { updates.removeValue(forKey: activity.id) }
    }
  }

  private func upload(_ token: Data, target: ActivityTokenSync.Target, activity: Live? = nil) async {
    guard sync.active == target, !Task.isCancelled, let site = URL(string: BackendEnvironment.site) else { return }
    var body = ["installationId": target.session.installation, "purpose": activity == nil ? "activity-start" : "activity",
                "language": Locale.preferredLanguages.first ?? "en", "token": token.map { String(format: "%02x", $0) }.joined()]
    if let activity {
      body["activityId"] = activity.attributes.activityId
      body["workspaceId"] = activity.attributes.workspaceId
    }
    var request = URLRequest(url: site.appendingPathComponent("api/live-activity/push-token"), timeoutInterval: 15)
    request.httpMethod = "POST"
    request.setValue("Bearer \(target.session.credential)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    do {
      request.httpBody = try JSONEncoder().encode(body)
    } catch {
      sync.recordUploadFailure(for: target)
      DiagnosticsStore.shared.record("notification", "activity_token_unconfirmed")
      return
    }
    // Keep the upload alive if the user locks or backgrounds the app right after starting a turn.
    let lease = BackgroundLease(name: "Upload Live Activity token")
    defer { lease.end() }
    for attempt in 0..<2 {
      guard sync.active == target, !Task.isCancelled else { return }
      do {
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return
      } catch {
        guard !Task.isCancelled, sync.active == target else { return }
        if attempt == 0 {
          try? await Task.sleep(nanoseconds: 1_500_000_000)
          continue
        }
        sync.recordUploadFailure(for: target)
        DiagnosticsStore.shared.record("notification", "activity_token_unconfirmed")
      }
    }
  }
}

@MainActor
private final class BackgroundLease {
  private var id: UIBackgroundTaskIdentifier = .invalid

  init(name: String) {
    id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
      Task { @MainActor in self?.end() }
    }
  }

  func end() {
    guard id != .invalid else { return }
    let active = id
    id = .invalid
    UIApplication.shared.endBackgroundTask(active)
  }
}
