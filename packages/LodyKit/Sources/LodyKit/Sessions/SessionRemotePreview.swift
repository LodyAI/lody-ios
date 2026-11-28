import Foundation

enum RemotePreviewTarget: Equatable, Sendable {
  case browser
  case iosSimulator
  case androidEmulator
}

enum RemotePreviewDecision: Equatable, Sendable {
  case openBrowser
  case browserEmpty
  case openDevice(DevicePlatform)
  case requiresMacOS
  case upgradeRequired(RemotePreviewTarget)
  case ownerOnly
  case machineOffline
}

/// Pure eligibility and routing rules for the session More menu's Remote preview submenu.
enum SessionRemotePreview {
  static func isIosSimulatorDimmed(machineSimulator: String?) -> Bool {
    machineSimulator == nil
  }

  static func isBrowserServerStoppedError(_ errorCode: String?) -> Bool {
    errorCode == "port_not_listening" || errorCode == "local_server_unreachable"
  }

  static func evaluate(
    _ target: RemotePreviewTarget,
    sessionUserId: String?,
    currentUserId: String,
    machineSimulator: String?,
    machineEmulator: String?,
    machineCapabilities: [String: Int]?,
    machineOnline: Bool?,
    hasBrowserCandidate: Bool,
    hasCachedBrowser: Bool,
    iosRunning: Bool,
    androidRunning: Bool
  ) -> RemotePreviewDecision {
    // Non-macOS computers always explain why the dimmed iOS Simulator entry cannot start.
    if target == .iosSimulator, isIosSimulatorDimmed(machineSimulator: machineSimulator) {
      return .requiresMacOS
    }

    if let owner = sessionUserId, !owner.isEmpty, !currentUserId.isEmpty, owner != currentUserId {
      return .ownerOnly
    }

    switch target {
    case .browser:
      if !hasBrowserCandidate,
         let capabilities = machineCapabilities,
         !capabilities.isEmpty,
         (capabilities["previewControl"] ?? 0) < 1 {
        return .upgradeRequired(.browser)
      }
      if hasBrowserCandidate {
        if !hasCachedBrowser, machineOnline == false {
          return .machineOffline
        }
        return .openBrowser
      }
      return .browserEmpty

    case .iosSimulator:
      if machineSimulator == "upgrade-required" {
        return .upgradeRequired(.iosSimulator)
      }
      if machineOnline == false, !iosRunning {
        return .machineOffline
      }
      return .openDevice(.ios)

    case .androidEmulator:
      if machineEmulator != "available" {
        return .upgradeRequired(.androidEmulator)
      }
      if machineOnline == false, !androidRunning {
        return .machineOffline
      }
      return .openDevice(.android)
    }
  }
}
