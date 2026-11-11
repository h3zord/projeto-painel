import Darwin
import Foundation

/// Inspeciona os registros vivos do Claude Code (`sessions/*.json`), confere o PID via `kill(pid, 0)`
/// e lê no máximo os últimos 3 MB de cada `.jsonl` em modo somente-leitura.
nonisolated struct ActiveConversationCollector: ConversationCollecting {
  static let tailByteCount = 3_000_000
  static let maxRegistryFileBytes = 65_536

  struct OpenSession: Equatable, Sendable {
    let name: String
    let transcriptURL: URL
  }

  private struct SessionRecord: Decodable {
    let pid: Int32
    let sessionId: String
    let name: String?

    enum CodingKeys: String, CodingKey {
      case pid
      case sessionId
      case name
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      if let numericPID = try? container.decode(Int32.self, forKey: .pid) {
        self.pid = numericPID
      } else {
        let stringPID = try container.decode(String.self, forKey: .pid)
        guard let parsedPID = Int32(stringPID) else {
          throw DecodingError.dataCorruptedError(
            forKey: .pid,
            in: container,
            debugDescription: "PID inválido"
          )
        }
        self.pid = parsedPID
      }
      self.sessionId = try container.decode(String.self, forKey: .sessionId)
      self.name = try container.decodeIfPresent(String.self, forKey: .name)
    }
  }

  let claudeSessionsURL: URL
  let claudeProjectsURL: URL
  private let processAliveChecker: @Sendable (Int32) -> Bool

  init(
    config: AppConfig,
    isProcessAlive: @escaping @Sendable (Int32) -> Bool = Self.isProcessAlive
  ) {
    self.claudeSessionsURL = config.claudeSessionsDirectory
    self.claudeProjectsURL = config.claudeProjectsDirectory
    self.processAliveChecker = isProcessAlive
  }

  init(
    claudeSessionsURL: URL,
    claudeProjectsURL: URL,
    isProcessAlive: @escaping @Sendable (Int32) -> Bool = Self.isProcessAlive
  ) {
    self.claudeSessionsURL = claudeSessionsURL
    self.claudeProjectsURL = claudeProjectsURL
    self.processAliveChecker = isProcessAlive
  }

  @concurrent
  func fetchActiveConversations() async throws -> [ActiveConversation] {
    let sessions = try openSessions()
    var conversations: [ActiveConversation] = []
    conversations.reserveCapacity(sessions.count)

    for session in sessions {
      let tokens = try Self.contextTokensOfTranscript(at: session.transcriptURL)
      conversations.append(
        ActiveConversation(
          id: session.transcriptURL.path,
          name: session.name,
          providerID: "claude",
          providerName: "Claude",
          icon: .asset("ClaudeIcon"),
          tint: .orange,
          contextTokens: tokens,
          modelContextWindow: nil
        )
      )
    }

    return conversations.sorted { ($0.contextTokens ?? 0) > ($1.contextTokens ?? 0) }
  }

  func openSessions() throws(AppError) -> [OpenSession] {
    let sessionFiles = try Self.jsonFiles(in: claudeSessionsURL)
    let projectDirectories = try Self.listDirectory(
      claudeProjectsURL,
      keys: [.isDirectoryKey]
    )

    var results: [OpenSession] = []
    var seenPaths: Set<String> = []
    let decoder = JSONDecoder()

    for fileURL in sessionFiles {
      guard
        let record = Self.loadSessionRecord(at: fileURL, decoder: decoder),
        processAliveChecker(record.pid),
        Self.isSafeSessionIdentifier(record.sessionId),
        let transcriptURL = Self.claudeTranscript(
          for: record.sessionId,
          in: projectDirectories
        )
      else {
        continue
      }

      let canonicalPath = transcriptURL.standardizedFileURL.path
      guard seenPaths.insert(canonicalPath).inserted else { continue }

      let trimmedName = record.name?.trimmingCharacters(in: .whitespacesAndNewlines)
      let resolvedName: String
      if let trimmedName, !trimmedName.isEmpty {
        resolvedName = trimmedName
      } else {
        resolvedName = "sem nome \(record.sessionId.prefix(8))"
      }

      results.append(OpenSession(name: resolvedName, transcriptURL: transcriptURL))
    }

    return results
  }

  static func isProcessAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    return Darwin.kill(pid, 0) == 0
  }

  static func contextTokensOfTranscript(
    at url: URL,
    maxTailBytes: Int = tailByteCount
  ) throws(AppError) -> Int? {
    guard let lines = try tailLines(at: url, maxBytes: maxTailBytes) else {
      return nil
    }
    return ClaudeTranscriptParser.contextTokens(in: lines)
  }

  private static func isSafeSessionIdentifier(_ identifier: String) -> Bool {
    !identifier.isEmpty
      && identifier.count <= 128
      && !identifier.contains("/")
      && !identifier.contains("..")
      && !identifier.contains("\0")
  }

  private static func isMissingPathError(_ error: NSError, at url: URL) -> Bool {
    let isBrokenSymlink =
      (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    if isBrokenSymlink {
      return false
    }
    if error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoSuchFile.rawValue {
      return true
    }
    if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
      return true
    }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
      underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOENT)
    {
      return true
    }
    return false
  }

  private static func listDirectory(
    _ directory: URL,
    keys: [URLResourceKey] = []
  ) throws(AppError) -> [URL] {
    do {
      return try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles]
      )
    } catch {
      let nsError = error as NSError
      if isMissingPathError(nsError, at: directory) {
        return []
      }
      throw AppError.transcriptReadFailed()
    }
  }

  private static func jsonFiles(in directory: URL) throws(AppError) -> [URL] {
    let urls = try listDirectory(directory)
    return
      urls
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func loadSessionRecord(at url: URL, decoder: JSONDecoder) -> SessionRecord? {
    guard
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
      values.isRegularFile == true,
      let size = values.fileSize,
      size <= maxRegistryFileBytes,
      let data = try? Data(contentsOf: url)
    else {
      return nil
    }
    return try? decoder.decode(SessionRecord.self, from: data)
  }

  private static func claudeTranscript(
    for sessionID: String,
    in projectDirectories: [URL]
  ) -> URL? {
    let targetFilename = "\(sessionID).jsonl"
    var newestURL: URL?
    var newestDate: Date = .distantPast

    for directory in projectDirectories {
      let candidate = directory.appending(path: targetFilename)
      guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
      let mtime =
        (try? candidate.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate) ?? .distantPast
      if newestURL == nil || mtime >= newestDate {
        newestURL = candidate
        newestDate = mtime
      }
    }

    return newestURL
  }

  private static func tailLines(at url: URL, maxBytes: Int) throws(AppError) -> [Substring]? {
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else {
        throw AppError.transcriptReadFailed()
      }
    } catch let appError as AppError {
      throw appError
    } catch {
      let nsError = error as NSError
      if isMissingPathError(nsError, at: url) {
        return nil
      }
      throw AppError.transcriptReadFailed()
    }

    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }

      let totalSize = try handle.seekToEnd()
      let clampedMax = max(maxBytes, 1)
      let startOffset = totalSize > UInt64(clampedMax) ? totalSize - UInt64(clampedMax) : 0
      try handle.seek(toOffset: startOffset)

      guard let data = try handle.readToEnd(), !data.isEmpty else { return [] }
      let text = String(decoding: data, as: UTF8.self)
      var rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)

      // Ao buscar no meio do arquivo, a primeira fatia pode ser o fim truncado de uma linha anterior.
      if startOffset > 0, !rawLines.isEmpty {
        rawLines.removeFirst()
      }

      return rawLines.filter { !$0.isEmpty }
    } catch {
      throw AppError.transcriptReadFailed()
    }
  }
}
