import Foundation
import CryptoKit
import ImageIO
import UIKit
import UniformTypeIdentifiers

final class AttachmentDownloadBatch {
  private let root: URL
  private var directories: [URL] = []
  private var handedOff = false

  init(root: URL = FileManager.default.temporaryDirectory) {
    self.root = root
  }

  func makeDirectory() -> URL {
    let directory = root.appendingPathComponent(UUID().uuidString)
    directories.append(directory)
    return directory
  }

  func handOff() {
    handedOff = true
  }

  deinit {
    guard !handedOff else { return }
    for directory in directories {
      try? FileManager.default.removeItem(at: directory)
    }
  }
}

/// Upload bytes in native code; only the server's attachment references enter Streams.
enum SessionAttachments {
  typealias ProgressHandler = @Sendable (_ attachmentID: String, _ phase: String, _ percent: Int?) -> Void
  typealias UploadedHandler = @Sendable (_ attachmentID: String, _ block: [String: Any]) -> Void
  typealias SleepHandler = @Sendable (UInt64) async throws -> Void

  struct RetryPolicy: Sendable {
    var maxAttempts: Int
    var sleep: SleepHandler?

    init(maxAttempts: Int, sleep: SleepHandler? = nil) {
      self.maxAttempts = maxAttempts
      self.sleep = sleep
    }

    static let single = RetryPolicy(maxAttempts: 1)
    static let upload = RetryPolicy(maxAttempts: 3)
  }

  static var outboxDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Lody\(BackendEnvironment.storageSuffix)/OutboxAttachments", isDirectory: true)
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

  static func isAllowedFile(_ url: URL, roots: [URL]? = nil) -> Bool {
    guard url.isFileURL, !url.hasDirectoryPath, !url.path.isEmpty else { return false }
    guard !url.path.split(separator: "/").contains("..") else { return false }
    if (try? FileManager.default.attributesOfItem(atPath: url.path))?[FileAttributeKey.type] as? FileAttributeType == .typeSymbolicLink {
      return false
    }
    let resolved = canonicalPath(url)
    let allowed = roots ?? [FileManager.default.temporaryDirectory, outboxDirectory]
    return allowed.contains { resolved.hasPrefix(canonicalPath($0) + "/") }
  }

  private static func validUploadedBlock(_ raw: Any?) -> [String: Any]? {
    guard let block = raw as? [String: Any],
          let kind = block["type"] as? String, ["image", "file"].contains(kind),
          let id = block[kind == "image" ? "imageId" : "fileId"] as? String, !id.isEmpty,
          block["mimeType"] is String,
          let bytes = block["sizeBytes"] as? Int, bytes > 0 else { return nil }
    if kind == "file" {
      guard block["transport"] as? String == "r2",
            block["sha256"] is String,
            block["fileName"] is String,
            block["textPreview"] is Bool,
            block["uploadedAt"] as? NSNumber != nil else { return nil }
    }
    return block
  }

  private static func isRetryableUploadFailure(_ failure: NSError) -> Bool {
    if failure.domain == NSURLErrorDomain {
      let retryableCodes: Set<Int> = [
        NSURLErrorTimedOut,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorResourceUnavailable,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorCallIsActive,
        NSURLErrorDataNotAllowed,
      ]
      return retryableCodes.contains(failure.code)
    }
    if failure.domain == "SessionAttachments" {
      return [408, 429, 500, 502, 503, 504].contains(failure.code)
    }
    return false
  }

  static func error(_ message: String) -> NSError {
    NSError(domain: "SessionAttachments", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
  static func segment(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")))!
  }

  static func imageDownloadURL(workspace: String, session: String, imageId: String) -> URL {
    let path = [workspace, session, imageId].map(segment)
    return URL(string: "\(BackendEnvironment.worker)/api/workspaces/\(path[0])/session-images/\(path[1])/\(path[2])")!
  }

  static func imageThumbnailURL(workspace: String, session: String, imageId: String, width: Int) -> URL {
    var components = URLComponents(
      url: imageDownloadURL(workspace: workspace, session: session, imageId: imageId)
        .appendingPathComponent("thumbnail"),
      resolvingAgainstBaseURL: false
    )!
    components.queryItems = [
      URLQueryItem(name: "width", value: String(width)),
      URLQueryItem(name: "fit", value: "scale-down"),
      URLQueryItem(name: "quality", value: "85"),
    ]
    return components.url!
  }
  static func upload(_ attachments: [[String: Any]], workspace: String, session: String, pins: WorkspaceModePins = .shared,
    allowedRoots: [URL]? = nil, retry: RetryPolicy = .upload,
    onProgress: @escaping ProgressHandler = { _, _, _ in },
    onUploaded: UploadedHandler? = nil) async throws -> [[String: Any]] {
    try pins.requirePlaintext(workspace)
    guard attachments.count <= 16,
          attachments.filter({ $0["kind"] as? String == "image" }).count <= 8,
          attachments.filter({ $0["kind"] as? String == "file" }).count <= 8 else {
      throw error(String(localized: "native.attachment.error.limit", bundle: .lody))
    }
    var blocks: [[String: Any]] = []
    var token: String?
    for attachment in attachments {
      try Task.checkCancellation()
      let attachmentID = attachment["id"] as? String ?? ""
      if let reused = validUploadedBlock(attachment["uploadedBlock"]) {
        blocks.append(reused)
        onProgress(attachmentID, "complete", 100)
        continue
      }
      if token == nil {
        guard let loaded = try AuthKeychain.read() else {
          throw error(String(localized: "native.attachment.error.signIn", bundle: .lody))
        }
        token = loaded
      }
      let bearer = token!
      guard let uri = attachment["uri"] as? String, let url = URL(string: uri),
            isAllowedFile(url, roots: allowedRoots),
            let name = attachment["name"] as? String, !name.isEmpty,
            var kind = attachment["kind"] as? String, ["image", "file"].contains(kind) else {
        throw error(String(localized: "native.attachment.error.invalid", bundle: .lody))
      }
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw error(String(localized: "native.attachment.error.missing", bundle: .lody))
      }
      let attempt = UUID()
      onProgress(attachmentID, "preparing", nil)
      let report: @Sendable (Int64, Int64) -> Void = { sent, total in
        guard total > 0 else { return }
        let percent = min(100, max(0, Int(Double(sent) / Double(total) * 100)))
        onProgress(attachmentID, sent >= total ? "verifying" : "uploading", percent)
      }
      if kind == "image", UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true {
        kind = "file"
      }
      let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard size.isRegularFile == true, let count = size.fileSize, count > 0, count <= 100 * 1024 * 1024 else {
        throw error(String(localized: "native.attachment.error.empty", bundle: .lody))
      }
      let base = "\(BackendEnvironment.worker)/api/workspaces/\(segment(workspace))/session-\(kind == "image" ? "images" : "files")"
      var responseStage: StaticString = kind == "image" ? "image_upload" : "file_upload"
      var result: [String: Any]
      if kind == "image" {
        // The server checks the bytes against the declared type, so classify the content
        // rather than the name: an edited Photos asset keeps its original `.PNG` name
        // while its rendered data is JPEG or HEIC.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
          throw error(String(localized: "native.attachment.error.imageRead", bundle: .lody))
        }
        let mime = (CGImageSourceGetType(source) as String?).flatMap { UTType($0)?.preferredMIMEType } ?? ""
        var bytes: Data
        var fileName = name
        var contentType = mime
        let converted: Bool
        if ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(mime), count <= 5 * 1024 * 1024 {
          bytes = try Data(contentsOf: url)
          converted = false
          if UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType != mime,
             let ext = UTType(mimeType: mime)?.preferredFilenameExtension {
            fileName = (name as NSString).deletingPathExtension + "." + ext
          }
        } else {
          guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2048,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary), let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else {
            throw error(String(localized: "native.attachment.error.imageRead", bundle: .lody))
          }
          bytes = jpeg; contentType = "image/jpeg"; converted = true
          fileName = (name as NSString).deletingPathExtension + ".jpg"
        }
        DiagnosticsStore.shared.record("attachment", "image_prepared", fields: [
          "attempt": attempt.uuidString, "session": DiagnosticsStore.correlation(session),
          "sourceType": DiagnosticsStore.attachmentMediaType(mime),
          "uploadType": DiagnosticsStore.attachmentMediaType(contentType),
          "sourceBytes": String(count), "imageBytes": String(bytes.count),
          "converted": String(converted),
        ])
        guard bytes.count <= 5 * 1024 * 1024 else { throw error(String(localized: "native.attachment.error.imageTooLarge", bundle: .lody)) }
        let boundary = UUID().uuidString
        let safeName = fileName.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"sessionId\"\r\n\r\n\(session)\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8)
        body.append(bytes); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        result = try await request(base + "/upload", workspace: workspace, pins: pins, token: bearer, stage: responseStage, attempt: attempt, headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"], body: body, retry: retry, onProgress: report)
      } else {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
          try Task.checkCancellation(); hash.update(data: data)
        }
        try file.seek(toOffset: 0)
        let prefix = try file.read(upToCount: 8192) ?? Data()
        try file.seek(toOffset: 0)
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let headers = ["x-session-id": session, "x-file-name": segment(name), "x-file-mime-type": mime,
          "x-file-sha256": hash.finalize().map { String(format: "%02x", $0) }.joined(),
          "x-file-size-bytes": String(count), "x-file-text-preview": String(!prefix.contains(0) && String(data: prefix, encoding: .utf8) != nil)]
        let partSize = 16 * 1024 * 1024
        if count <= partSize {
          result = try await request(base + "/upload", workspace: workspace, pins: pins, token: bearer, stage: responseStage, attempt: attempt, headers: headers, body: try file.readToEnd(), retry: retry, onProgress: report)
        } else {
          let created = try await request(base + "/multipart/create", workspace: workspace, pins: pins, token: bearer, stage: "multipart_create", attempt: attempt, headers: headers, retry: retry)
          guard let uploadId = created["uploadId"] as? String, !uploadId.isEmpty,
                let fileId = created["fileId"] as? String, !fileId.isEmpty else { throw invalidResponse(stage: "multipart_create", attempt: attempt) }
          let path = base + "/multipart/" + segment(uploadId)
          let identity = ["x-session-id": session, "x-file-id": fileId]
          do {
            var parts: [[String: Any]] = []
            while let data = try file.read(upToCount: partSize), !data.isEmpty {
              let number = parts.count + 1
              let offset = Int64(parts.count * partSize)
              let part = try await request(path + "/part/\(number)", workspace: workspace, pins: pins, token: bearer, stage: "multipart_part", attempt: attempt, method: "PUT", headers: identity.merging(["x-file-part-size-bytes": String(data.count)], uniquingKeysWith: { _, new in new }), body: data,
                retry: retry,
                onProgress: { sent, _ in report(offset + sent, Int64(count)) })
              guard let etag = part["etag"] as? String, !etag.isEmpty else { throw invalidResponse(stage: "multipart_part", attempt: attempt) }
              parts.append(["partNumber": number, "etag": etag])
              report(offset + Int64(data.count), Int64(count))
            }
            responseStage = "multipart_complete"
            result = try await request(path + "/complete", workspace: workspace, pins: pins, token: bearer, stage: responseStage, attempt: attempt, headers: identity.merging(["Content-Type": "application/json"], uniquingKeysWith: { _, new in new }), body: JSONSerialization.data(withJSONObject: ["parts": parts]), retry: retry)
          } catch {
            // Cleanup also runs after cancellation; never retry message dispatch.
            await Task.detached { _ = try? await request(path + "/abort", workspace: workspace, pins: pins, token: bearer, stage: "multipart_abort", attempt: attempt, method: "DELETE", headers: identity) }.value
            throw error
          }
        }
      }
      guard let block = result[kind] as? [String: Any], block["type"] as? String == kind,
            let id = block[kind == "image" ? "imageId" : "fileId"] as? String, !id.isEmpty,
            block["mimeType"] is String, let bytes = block["sizeBytes"] as? Int, bytes > 0 else {
        throw invalidResponse(stage: responseStage, attempt: attempt)
      }
      blocks.append(block)
      onUploaded?(attachmentID, block)
      onProgress(attachmentID, "complete", 100)
    }
    return blocks
  }

  /// Download to disk so a video never becomes a base64 or in-memory file body.
  static func download(workspace: String, session: String, fileId: String, fileName: String, sizeBytes: Int?, directory: URL, image: Bool = false) async throws -> URL {
    guard !workspace.isEmpty, !session.isEmpty, !fileId.isEmpty else {
      throw error(String(localized: "native.attachment.error.invalid", bundle: .lody))
    }
    let limit = 100 * 1024 * 1024
    if let sizeBytes, sizeBytes <= 0 || sizeBytes > limit {
      throw error(String(localized: "native.attachment.error.tooLarge", bundle: .lody))
    }
    guard let token = try AuthKeychain.read() else { throw error(String(localized: "native.attachment.error.signIn", bundle: .lody)) }
    let path = [workspace, session, fileId].map(segment)
    let kind = image ? "session-images" : "session-files"
    var request = URLRequest(url: URL(string: "\(BackendEnvironment.worker)/api/workspaces/\(path[0])/\(kind)/\(path[1])/\(path[2])")!, timeoutInterval: 120)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (temporary, response) = try await URLSession.shared.download(for: request)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try Task.checkCancellation()
    guard let response = response as? HTTPURLResponse else {
      throw error(String(localized: "native.attachment.error.download", bundle: .lody))
    }
    if response.statusCode == 404 || response.statusCode == 410 {
      throw error(String(localized: "native.attachment.error.unavailable", bundle: .lody))
    }
    if response.statusCode == 401 || response.statusCode == 403 {
      throw error(String(localized: "native.attachment.error.permissionDenied", bundle: .lody))
    }
    guard response.statusCode == 200 else { throw error(String(localized: "native.attachment.error.download", bundle: .lody)) }
    let count = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard count > 0, count <= limit, sizeBytes == nil || sizeBytes == count else {
      throw error(String(localized: "native.attachment.error.download", bundle: .lody))
    }
    let name = (fileName.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
    let safeName = name.isEmpty || name == "." || name == ".." ? "file" : name
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(safeName)
    try FileManager.default.moveItem(at: temporary, to: destination)
    return destination
  }

  private static func invalidResponse(stage: StaticString, attempt: UUID) -> NSError {
    DiagnosticsStore.shared.record("attachment", "invalid_response", fields: ["stage": stage.description, "attempt": attempt.uuidString])
    return error(String(localized: "native.attachment.error.uploadResponse", bundle: .lody))
  }

  private static func uploadError(status: Int, serverCode: String?) -> NSError {
    let key: String
    switch serverCode {
    case "quota_exceeded", "storage_quota_exceeded": key = "storageQuota"
    case "unauthorized": key = "uploadSignIn"
    case "forbidden": key = "uploadPermission"
    case "invalid_request", "bad_request": key = "uploadInvalid"
    case "not_found": key = "uploadUnavailable"
    case "internal_server_error", "service_unavailable": key = "uploadService"
    case "payload_too_large", "file_too_large": key = "uploadTooLarge"
    case "unsupported_media_type": key = "uploadFormat"
    case "rate_limited", "rate_limit_exceeded": key = "rateLimited"
    default:
      switch status {
      case 400, 422: key = "uploadInvalid"
      case 401: key = "uploadSignIn"
      case 403: key = "uploadPermission"
      case 404, 410: key = "uploadUnavailable"
      case 413: key = "uploadTooLarge"
      case 415: key = "uploadFormat"
      case 429: key = "rateLimited"
      case 500...599: key = "uploadService"
      default: key = "upload"
      }
    }
    let detail = String(localized: String.LocalizationValue("native.attachment.error." + key), bundle: .lody)
    return NSError(domain: "SessionAttachments", code: status,
      userInfo: [NSLocalizedDescriptionKey: "\(detail) (HTTP \(status))"])
  }

  static func request(_ url: String, workspace: String? = nil, pins: WorkspaceModePins = .shared, token: String, stage: StaticString, attempt: UUID, method: String = "POST", headers: [String: String], body: Data? = nil,
    retry: RetryPolicy = .single,
    onProgress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> [String: Any] {
    let totalAttempts = max(1, retry.maxAttempts)
    let backoffs: [UInt64] = [350_000_000, 1_000_000_000]
    var index = 0
    while true {
      try Task.checkCancellation()
      do {
        return try await requestOnce(
          url, workspace: workspace, pins: pins, token: token, stage: stage, attempt: attempt,
          method: method, headers: headers, body: body, onProgress: onProgress
        )
      } catch let failure as NSError {
        index += 1
        guard index < totalAttempts, !Task.isCancelled, isRetryableUploadFailure(failure) else {
          throw failure
        }
        let delay = backoffs[min(index - 1, backoffs.count - 1)]
        if let sleep = retry.sleep {
          try await sleep(delay)
        } else {
          try await Task.sleep(nanoseconds: delay)
        }
      }
    }
  }

  private static func requestOnce(_ url: String, workspace: String?, pins: WorkspaceModePins, token: String, stage: StaticString, attempt: UUID, method: String, headers: [String: String], body: Data?,
    onProgress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws -> [String: Any] {
    try Task.checkCancellation()
    if let workspace, stage.description != "multipart_abort" { try pins.requirePlaintext(workspace) }
    var request = URLRequest(url: URL(string: url)!, timeoutInterval: 120)
    request.httpMethod = method; request.httpBody = body
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    var fields = ["stage": stage.description, "attempt": attempt.uuidString,
      "requestBytes": String(body?.count ?? 0)]
    let started = ProcessInfo.processInfo.systemUptime
    DiagnosticsStore.shared.record("attachment", "request_started", fields: fields)
    let data: Data
    let response: URLResponse
    do {
      if let body, let onProgress {
        request.httpBody = nil
        onProgress(0, Int64(body.count))
        (data, response) = try await URLSession.shared.upload(for: request, from: body,
          delegate: AttachmentUploadDelegate(onProgress: onProgress))
        onProgress(Int64(body.count), Int64(body.count))
      } else {
        (data, response) = try await URLSession.shared.data(for: request)
      }
    } catch {
      let failure = error as NSError
      fields["elapsedMs"] = String(Int(max(0, ProcessInfo.processInfo.systemUptime - started) * 1000))
      if failure.domain == NSURLErrorDomain { fields["networkCode"] = String(failure.code) }
      DiagnosticsStore.shared.record("attachment", "transport_failed", fields: fields)
      let key: String
      switch failure.domain == NSURLErrorDomain ? failure.code : 0 {
      case NSURLErrorTimedOut: key = "native.attachment.error.timeout"
      case NSURLErrorCancelled: key = "native.attachment.error.cancelled"
      case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
        key = "native.attachment.error.network"
      default: key = "native.attachment.error.connection"
      }
      throw NSError(domain: failure.domain, code: failure.code,
        userInfo: [NSLocalizedDescriptionKey: String(localized: String.LocalizationValue(key), bundle: .lody)])
    }
    guard let response = response as? HTTPURLResponse else {
      throw invalidResponse(stage: stage, attempt: attempt)
    }
    fields["httpStatus"] = String(response.statusCode)
    fields["elapsedMs"] = String(Int(max(0, ProcessInfo.processInfo.systemUptime - started) * 1000))
    fields["responseBytes"] = String(data.count)
    switch response.mimeType?.lowercased() {
    case "application/json", "application/problem+json": fields["responseType"] = "json"
    case "text/html": fields["responseType"] = "html"
    case "text/plain": fields["responseType"] = "text"
    case nil: fields["responseType"] = "missing"
    default: fields["responseType"] = "other"
    }
    fields["cfRay"] = response.value(forHTTPHeaderField: "CF-Ray")
    fields["requestId"] = response.value(forHTTPHeaderField: "X-Request-ID")
    guard (200..<300).contains(response.statusCode) else {
      // Classify bounded responses without persisting their text, keys or arbitrary codes.
      fields["serverCodeState"] = "missing"
      if data.isEmpty {
        fields["responseBody"] = "empty"
      } else if data.count > 64 * 1024 {
        fields["responseBody"] = "too_large"
      } else {
        fields["serverErrorFingerprint"] = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
          fields["responseBody"] = "json_other"
          if let value = json as? [String: Any] {
            fields["responseBody"] = "json_object"
            let detail = value["error"] as? [String: Any]
            let candidates = [value["code"], detail?["code"], value["error"], detail?["message"], value["message"]]
              .compactMap { $0 as? String }.filter { !$0.isEmpty }
            // An unrecognized top-level code must not mask a recognized nested category.
            if let code = candidates.compactMap(DiagnosticsStore.attachmentServerCode).first {
              fields["serverCode"] = code
              fields["serverCodeState"] = "recognized"
            } else if !candidates.isEmpty {
              fields["serverCodeState"] = "unrecognized"
            }
          }
        } else {
          fields["responseBody"] = "invalid_json"
        }
      }
      DiagnosticsStore.shared.record("attachment", "http_failed", fields: fields)
      throw uploadError(status: response.statusCode, serverCode: fields["serverCode"])
    }
    if data.isEmpty {
      DiagnosticsStore.shared.record("attachment", "request_succeeded", fields: fields)
      return [:]
    }
    let value: [String: Any]
    do {
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw error(String(localized: "native.attachment.error.uploadResponse", bundle: .lody))
      }
      value = object
    } catch {
      DiagnosticsStore.shared.record("attachment", "invalid_response", fields: fields)
      throw error
    }
    DiagnosticsStore.shared.record("attachment", "request_succeeded", fields: fields)
    return value
  }
}

final class AttachmentUploadDelegate: NSObject, URLSessionTaskDelegate {
  private let onProgress: @Sendable (Int64, Int64) -> Void
  init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) { self.onProgress = onProgress }
  func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
    onProgress(totalBytesSent, totalBytesExpectedToSend)
  }
}
