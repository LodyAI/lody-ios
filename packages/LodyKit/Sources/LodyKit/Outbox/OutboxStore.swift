import Foundation

struct OutboxPersistence: Sendable {
  var generation: @Sendable () -> Int
  var read: @Sendable (String) async -> String?
  var write: @Sendable (_ key: String, _ value: String, _ generation: Int) async throws -> Void
  var attachmentsDirectory: URL? = nil
}

enum OutboxError: Error, Equatable {
  case scopeExpired
  case invalidRecord
}

@MainActor
final class OutboxStore {
  struct Snapshot: Equatable {
    var records: [OutboxRecord] = []
    var ready = false
  }

  let key: String
  let generation: Int
  private(set) var snapshot = Snapshot()
  private(set) var revision = 0
  var onChange: (() -> Void)?
  private let persistence: OutboxPersistence
  private let admit: () throws -> Void
  private var durable: [OutboxRecord] = []
  private var touched = Set<String>()
  private var writes: Task<Void, Never>

  init(key: String, generation: Int, persistence: OutboxPersistence, awaitingConfirmation: String, admit: @escaping () throws -> Void = {}) {
    self.key = key
    self.generation = generation
    self.persistence = persistence
    self.admit = admit
    writes = Task {}
    writes = Task { @MainActor [weak self] in
      let saved = await persistence.read(key)
      guard let self, generation == persistence.generation() else { return }
      self.durable = OutboxRecord.restore(
        saved, awaitingConfirmation: awaitingConfirmation, attachmentsDirectory: persistence.attachmentsDirectory
      )
      let restored = self.durable.filter { !self.touched.contains($0.sessionId) }
      self.publish(restored + self.snapshot.records, ready: true)
    }
  }

  var json: String {
    let records = OutboxRecord.encode(snapshot.records)
    return #"{"ready":\#(snapshot.ready),"records":\#(records)}"#
  }

  @discardableResult
  func put(_ record: OutboxRecord) -> Task<Void, Error> {
    do { try admit() } catch { return Task { throw error } }
    return change(record.sessionId, record)
  }

  @discardableResult
  func remove(_ sessionId: String) -> Task<Void, Error> {
    change(sessionId, nil)
  }

  private var current: Bool { generation == persistence.generation() }

  private func change(_ sessionId: String, _ record: OutboxRecord?) -> Task<Void, Error> {
    guard current else { return Task { throw OutboxError.scopeExpired } }
    touched.insert(sessionId)
    publish(Self.replace(snapshot.records, sessionId, record), ready: snapshot.ready)
    let previous = writes, key = key, generation = generation, persistence = persistence
    let write = Task { @MainActor [weak self] in
      await previous.value
      guard let self, self.current else { throw OutboxError.scopeExpired }
      if record != nil { try self.admit() }
      let previousRecord = self.durable.first { $0.sessionId == sessionId }
      var resolved = record
      if var candidate = resolved, let previousRecord, previousRecord.sendId == candidate.sendId,
         case .array(let durableItems)? = previousRecord.send["attachments"],
         case .array(let nextItems)? = candidate.send["attachments"],
         durableItems.count == nextItems.count {
        var merged = false
        let combined = zip(durableItems, nextItems).map { oldItem, newItem -> OutboxValue in
          guard let oldObj = oldItem.object, var newObj = newItem.object,
                oldObj["id"] == newObj["id"] else { return newItem }
          var itemChanged = false
          if newObj["uploadedBlock"] == nil, let block = oldObj["uploadedBlock"] {
            newObj["uploadedBlock"] = block
            itemChanged = true
          }
          if let dir = persistence.attachmentsDirectory,
             let oldURI = oldObj["uri"]?.string, oldURI.contains("/OutboxAttachments/"),
             newObj["uri"]?.string != oldURI,
             let rebased = OutboxRecord.rebase(previousRecord, in: dir).send["attachments"],
             case .array(let rebasedItems) = rebased,
             let match = rebasedItems.first(where: { $0.object?["id"] == oldObj["id"] })?.object?["uri"] {
            newObj["uri"] = match
            itemChanged = true
          }
          if itemChanged { merged = true }
          return itemChanged ? .object(newObj) : newItem
        }
        if merged {
          candidate.send["attachments"] = .array(combined)
          resolved = candidate
        }
      }
      if let candidate = resolved, let dir = persistence.attachmentsDirectory {
        resolved = OutboxRecord.stage(candidate, storeKey: key, in: dir)
      }
      let next = Self.replace(self.durable, sessionId, resolved)
      try await persistence.write(key, OutboxRecord.encode(next), generation)
      guard self.current else { throw OutboxError.scopeExpired }
      self.durable = next
      if let dir = persistence.attachmentsDirectory, let previousRecord, previousRecord.sendId != resolved?.sendId {
        OutboxRecord.removeStagedAttachments(storeKey: key, sendId: previousRecord.sendId, in: dir)
      }
      if let resolved, resolved != record,
         let index = self.snapshot.records.firstIndex(where: { $0.sessionId == sessionId && $0.sendId == resolved.sendId }) {
        var updated = self.snapshot.records[index]
        if updated.send["attachments"] != resolved.send["attachments"] {
          updated.send["attachments"] = resolved.send["attachments"]
          var records = self.snapshot.records
          records[index] = updated
          self.snapshot = Snapshot(records: records, ready: self.snapshot.ready)
        }
      }
    }
    writes = Task { _ = await write.result }
    return write
  }

  private static func replace(_ records: [OutboxRecord], _ sessionId: String, _ record: OutboxRecord?) -> [OutboxRecord] {
    var next = records.filter { $0.sessionId != sessionId }
    if let record { next.append(record) }
    return next
  }

  private func publish(_ records: [OutboxRecord], ready: Bool) {
    snapshot = Snapshot(records: records, ready: ready)
    revision += 1
    onChange?()
  }
}

@MainActor
final class OutboxStores {
  private let persistence: OutboxPersistence
  private let awaitingConfirmation: () -> String
  private let admit: (String) throws -> Void
  private var stores: [String: OutboxStore] = [:]
  private var generation: Int
  var onChange: ((OutboxStore) -> Void)?
  var onReset: (() -> Void)?

  init(persistence: OutboxPersistence, admit: @escaping (String) throws -> Void = { _ in }, awaitingConfirmation: @escaping () -> String) {
    self.persistence = persistence
    self.awaitingConfirmation = awaitingConfirmation
    self.admit = admit
    generation = persistence.generation()
  }

  nonisolated static func key(user: String, workspace: String) -> String {
    user.isEmpty || workspace.isEmpty ? "" : "pending-sends:\(user):\(workspace)"
  }

  func store(user: String, workspace: String) -> OutboxStore? {
    let current = persistence.generation()
    if generation != current {
      stores.removeAll()
      generation = current
      onReset?()
    }
    let key = Self.key(user: user, workspace: workspace)
    guard !key.isEmpty else { return nil }
    if let store = stores[key] { return store }
    let admit = self.admit
    let store = OutboxStore(key: key, generation: current, persistence: persistence, awaitingConfirmation: awaitingConfirmation(), admit: { try admit(workspace) })
    store.onChange = { [weak self, unowned store] in self?.onChange?(store) }
    stores[key] = store
    return store
  }
}
