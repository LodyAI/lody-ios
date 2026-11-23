import Foundation
import LodyCore

typealias OutboxValue = RuntimeContract.JSONValue

extension RuntimeContract.JSONValue {
  var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var object: [String: OutboxValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  var truthy: Bool {
    switch self {
    case .null: return false
    case .bool(let value): return value
    case .number(let value): return value != 0 && !value.isNaN
    case .string(let value): return !value.isEmpty
    case .array, .object: return true
    }
  }
}

struct OutboxRecord: Codable, Sendable, Equatable {
  var session: [String: OutboxValue]
  var send: [String: OutboxValue]

  var sessionId: String { session["id"]?.string ?? "" }
  var sendId: String { send["id"]?.string ?? "" }
  var phase: String { send["phase"]?.string ?? "" }
  var creation: String? { send["creation"]?.truthy == true ? send["creation"]?.string : nil }

  func with(phase: String, reason: String? = nil, dropCreation: Bool = false) -> OutboxRecord {
    var next = self
    next.send["phase"] = .string(phase)
    if let reason { next.send["reason"] = .string(reason) }
    if dropCreation { next.send["creation"] = nil }
    return next
  }

  func recordingUploadedAttachment(id: String, block: OutboxValue) -> OutboxRecord {
    guard !id.isEmpty, case .array(let items)? = send["attachments"] else { return self }
    var changed = false
    let updated = items.map { item -> OutboxValue in
      guard var object = item.object, object["id"]?.string == id else { return item }
      if object["uploadedBlock"] == block { return item }
      object["uploadedBlock"] = block
      changed = true
      return .object(object)
    }
    guard changed else { return self }
    var next = self
    next.send["attachments"] = .array(updated)
    return next
  }

  static var defaultAttachmentsDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Lody\(BackendEnvironment.storageSuffix)/OutboxAttachments", isDirectory: true)
  }

  private static let attachmentsMarker = "/OutboxAttachments/"

  private static func safeSegment(_ value: String, fallback: String) -> String {
    let cleaned = value.unicodeScalars.map { scalar -> Character in
      if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "." {
        return Character(scalar)
      }
      return "_"
    }
    let result = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return result.isEmpty ? fallback : String(result.prefix(120))
  }

  private static func canonicalPath(_ url: URL) -> String {
    var current = url.standardizedFileURL
    var suffix: [String] = []
    while !FileManager.default.fileExists(atPath: current.path) {
      let name = current.lastPathComponent
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path || name.isEmpty { break }
      suffix.append(name)
      current = parent
    }
    var resolved = current.resolvingSymlinksInPath()
    for component in suffix.reversed() {
      resolved.appendPathComponent(component)
    }
    let path = resolved.path
    if path == "/private/var" { return "/var" }
    if path.hasPrefix("/private/var/") { return String(path.dropFirst("/private".count)) }
    if path == "/private/tmp" { return "/tmp" }
    if path.hasPrefix("/private/tmp/") { return String(path.dropFirst("/private".count)) }
    return path
  }

  static func rebase(_ record: OutboxRecord, in directory: URL?) -> OutboxRecord {
    guard let directory, case .array(let items)? = record.send["attachments"] else { return record }
    var changed = false
    let rebased = items.map { item -> OutboxValue in
      guard var object = item.object,
            let uri = object["uri"]?.string,
            let url = URL(string: uri), url.isFileURL,
            let range = url.path.range(of: attachmentsMarker, options: .backwards) else { return item }
      let relative = String(url.path[range.upperBound...])
      let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      guard !parts.isEmpty, parts.count <= 4,
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return item }
      let target = parts.reduce(directory) { $0.appendingPathComponent($1) }.absoluteString
      guard target != uri else { return item }
      object["uri"] = .string(target)
      changed = true
      return .object(object)
    }
    guard changed else { return record }
    var next = record
    next.send["attachments"] = .array(rebased)
    return next
  }

  static func stage(_ record: OutboxRecord, storeKey: String, in directory: URL) -> OutboxRecord {
    guard !record.sendId.isEmpty, case .array(let items)? = record.send["attachments"], !items.isEmpty else {
      return record
    }
    let tempPrefix = canonicalPath(FileManager.default.temporaryDirectory) + "/"
    let durablePrefix = canonicalPath(directory) + "/"
    let folder = directory
      .appendingPathComponent(safeSegment(storeKey, fallback: "scope"), isDirectory: true)
      .appendingPathComponent(safeSegment(record.sendId, fallback: "turn"), isDirectory: true)
    var createdFolder = false
    var changed = false
    let staged = items.map { item -> OutboxValue in
      guard var object = item.object else { return item }
      if object["uploadedBlock"]?.object != nil { return item }
      guard let uri = object["uri"]?.string, let source = URL(string: uri), source.isFileURL,
            !source.hasDirectoryPath, !source.path.split(separator: "/").contains("..") else { return item }
      if (try? FileManager.default.attributesOfItem(atPath: source.path))?[FileAttributeKey.type] as? FileAttributeType == .typeSymbolicLink {
        return item
      }
      let resolvedSource = canonicalPath(source)
      if resolvedSource.hasPrefix(durablePrefix) { return item }
      guard resolvedSource.hasPrefix(tempPrefix), FileManager.default.fileExists(atPath: source.path) else { return item }
      let leaf = safeSegment(source.lastPathComponent, fallback: UUID().uuidString)
      let destination = folder.appendingPathComponent(leaf, isDirectory: false)
      do {
        if !createdFolder {
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          var root = directory
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          try? root.setResourceValues(values)
          createdFolder = true
        }
        if !FileManager.default.fileExists(atPath: destination.path) {
          do { try FileManager.default.linkItem(at: source, to: destination) }
          catch { try FileManager.default.copyItem(at: source, to: destination) }
        }
        object["uri"] = .string(destination.absoluteString)
        changed = true
        return .object(object)
      } catch {
        return item
      }
    }
    guard changed else { return record }
    var next = record
    next.send["attachments"] = .array(staged)
    return next
  }

  static func removeStagedAttachments(storeKey: String, sendId: String, in directory: URL) {
    guard !sendId.isEmpty else { return }
    let scopeFolder = directory.appendingPathComponent(safeSegment(storeKey, fallback: "scope"), isDirectory: true)
    let sendFolder = scopeFolder.appendingPathComponent(safeSegment(sendId, fallback: "turn"), isDirectory: true)
    try? FileManager.default.removeItem(at: sendFolder)
    if let remaining = try? FileManager.default.contentsOfDirectory(atPath: scopeFolder.path), remaining.isEmpty {
      try? FileManager.default.removeItem(at: scopeFolder)
    }
  }

  static func restore(_ raw: String?, awaitingConfirmation: String, attachmentsDirectory: URL? = nil) -> [OutboxRecord] {
    guard let raw, let saved = try? JSONDecoder().decode(OutboxValue.self, from: Data(raw.utf8)),
          case .array(let items) = saved else { return [] }
    return items.compactMap { item in
      guard let session = item.object?["session"]?.object, session["id"]?.truthy == true,
            let send = item.object?["send"]?.object, send["id"]?.truthy == true,
            send["text"]?.string != nil, case .array? = send["attachments"],
            send["choice"]?.truthy == true else { return nil }
      var record = rebase(OutboxRecord(session: session, send: send), in: attachmentsDirectory)
      // An older client queued the displayed wording. Expanding its references requires a new tap.
      if record.send.removeValue(forKey: "literalReferences") == .bool(true), record.phase == "waiting" {
        return record.with(phase: "failed", reason: "mention_expansion_failed")
      }
      guard record.phase == "creating" || record.phase == "sending" else { return record }
      return record.with(phase: "unknown", reason: awaitingConfirmation)
    }
  }

  static func encode(_ records: [OutboxRecord]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return (try? encoder.encode(records)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
  }

  static func decode(_ json: String) -> OutboxRecord? {
    try? JSONDecoder().decode(OutboxRecord.self, from: Data(json.utf8))
  }
}
