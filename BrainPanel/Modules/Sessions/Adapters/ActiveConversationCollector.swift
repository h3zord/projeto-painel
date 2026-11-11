import Darwin
import Foundation
import SQLite3

/// Inspeciona sessões ativas do Claude Code (`sessions/*.json` + `claude-context/*.json`) e conversas
/// recentes do Antigravity (`brain/<cid>/.system_generated/logs/transcript*.jsonl`, `antigravity-names.json`
/// e `conversation_summaries.db`), operando em modo estritamente somente-leitura (até 4 MB do tail por transcript).
nonisolated struct ActiveConversationCollector: ConversationCollecting {
  static let tailByteCount = 4 * 1_024 * 1_024
  static let maxRegistryFileBytes = 65_536
  static let maxNamesFileBytes = 1_048_576
  static let minValidContextWindow = 1_000
  static let maxValidContextWindow = 50_000_000
  static let defaultAntigravityActiveWindowSeconds: TimeInterval = 2 * 3_600
  static let defaultMaxAntigravityConversations = 20

  struct OpenSession: Equatable, Sendable {
    let sessionId: String
    let explicitName: String?
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

  private struct ContextWindowRecord: Decodable {
    let window: Int?
  }

  private struct AntigravityCandidate {
    let cid: String
    let transcriptURL: URL
    let modifiedAt: Date
  }

  let claudeSessionsURL: URL
  let claudeProjectsURL: URL
  let claudeContextCacheURL: URL
  let antigravityURL: URL
  let brainSessionsStateURL: URL
  let antigravityActiveWindowSeconds: TimeInterval
  let maxAntigravityConversations: Int
  private let clock: any Clock
  private let processAliveChecker: @Sendable (Int32) -> Bool

  init(
    config: AppConfig,
    clock: any Clock = SystemClock(),
    antigravityActiveWindowSeconds: TimeInterval = Self.defaultAntigravityActiveWindowSeconds,
    maxAntigravityConversations: Int = Self.defaultMaxAntigravityConversations,
    isProcessAlive: @escaping @Sendable (Int32) -> Bool = Self.isProcessAlive
  ) {
    self.claudeSessionsURL = config.claudeSessionsDirectory
    self.claudeProjectsURL = config.claudeProjectsDirectory
    self.claudeContextCacheURL = config.claudeContextCacheDirectory
    self.antigravityURL = config.antigravityDirectory
    self.brainSessionsStateURL = config.brainSessionsStateDirectory
    self.antigravityActiveWindowSeconds = antigravityActiveWindowSeconds
    self.maxAntigravityConversations = maxAntigravityConversations
    self.clock = clock
    self.processAliveChecker = isProcessAlive
  }

  init(
    claudeSessionsURL: URL,
    claudeProjectsURL: URL,
    claudeContextCacheURL: URL? = nil,
    antigravityURL: URL? = nil,
    brainSessionsStateURL: URL? = nil,
    clock: any Clock = SystemClock(),
    antigravityActiveWindowSeconds: TimeInterval = Self.defaultAntigravityActiveWindowSeconds,
    maxAntigravityConversations: Int = Self.defaultMaxAntigravityConversations,
    isProcessAlive: @escaping @Sendable (Int32) -> Bool = Self.isProcessAlive
  ) {
    let fallbackBase = claudeSessionsURL.deletingLastPathComponent()
    self.claudeSessionsURL = claudeSessionsURL
    self.claudeProjectsURL = claudeProjectsURL
    self.claudeContextCacheURL =
      claudeContextCacheURL
      ?? fallbackBase.appending(path: "unused-claude-context", directoryHint: .isDirectory)
    self.antigravityURL =
      antigravityURL
      ?? fallbackBase.appending(path: "unused-antigravity-cli", directoryHint: .isDirectory)
    self.brainSessionsStateURL =
      brainSessionsStateURL
      ?? fallbackBase.appending(path: "unused-brain-sessions", directoryHint: .isDirectory)
    self.antigravityActiveWindowSeconds = antigravityActiveWindowSeconds
    self.maxAntigravityConversations = maxAntigravityConversations
    self.clock = clock
    self.processAliveChecker = isProcessAlive
  }

  @concurrent
  func fetchActiveConversations() async throws -> [ActiveConversation] {
    let claudeConversations = try collectClaudeConversations()
    let antigravityConversations = collectAntigravityConversations(now: clock.now())
    return ActiveConversation.prioritized(claudeConversations + antigravityConversations)
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

      results.append(
        OpenSession(
          sessionId: record.sessionId,
          explicitName: SessionNameSanitizer.clean(record.name),
          transcriptURL: transcriptURL
        )
      )
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

  private func collectClaudeConversations() throws(AppError) -> [ActiveConversation] {
    let sessions = try openSessions()
    var conversations: [ActiveConversation] = []
    conversations.reserveCapacity(sessions.count)
    let decoder = JSONDecoder()

    for session in sessions {
      let snapshot: TranscriptSnapshot
      if let lines = try Self.tailLines(at: session.transcriptURL, maxBytes: Self.tailByteCount) {
        snapshot = ClaudeTranscriptParser.parse(lines: lines)
      } else {
        snapshot = .empty
      }

      let resolvedName =
        session.explicitName
        ?? snapshot.sessionName
        ?? "sem nome \(session.sessionId.prefix(8))"

      let recordedWindow = Self.loadRecordedContextWindow(
        for: session.sessionId,
        in: claudeContextCacheURL,
        decoder: decoder
      )

      conversations.append(
        ActiveConversation(
          id: session.transcriptURL.path,
          name: resolvedName,
          providerID: "claude",
          providerName: "Claude",
          icon: .asset("ClaudeIcon"),
          tint: .orange,
          contextTokens: snapshot.contextTokens,
          modelContextWindow: recordedWindow,
          compaction: snapshot.compaction
        )
      )
    }

    return conversations
  }

  private func collectAntigravityConversations(now: Date) -> [ActiveConversation] {
    guard maxAntigravityConversations > 0 else { return [] }

    let brainDir = antigravityURL.appending(path: "brain", directoryHint: .isDirectory)
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: brainDir,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    let cutoff = now.addingTimeInterval(-max(antigravityActiveWindowSeconds, 0))
    var candidates: [AntigravityCandidate] = []

    for entryURL in entries {
      let cid = entryURL.lastPathComponent
      guard
        Self.isSafeSessionIdentifier(cid),
        (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
        let (transcriptURL, mtime) = Self.antigravityTranscript(in: entryURL),
        mtime >= cutoff
      else {
        continue
      }
      candidates.append(
        AntigravityCandidate(cid: cid, transcriptURL: transcriptURL, modifiedAt: mtime)
      )
    }

    guard !candidates.isEmpty else { return [] }

    candidates.sort { lhs, rhs in
      if lhs.modifiedAt != rhs.modifiedAt {
        return lhs.modifiedAt > rhs.modifiedAt
      }
      return lhs.cid < rhs.cid
    }
    let selectedCandidates = Array(candidates.prefix(maxAntigravityConversations))

    let namesFileURL = brainSessionsStateURL.appending(path: "antigravity-names.json")
    let namesByCID = Self.loadAntigravityNames(at: namesFileURL)

    let idsMissingName = selectedCandidates.map(\.cid).filter {
      SessionNameSanitizer.clean(namesByCID[$0]) == nil
    }
    let titlesByCID =
      idsMissingName.isEmpty
      ? [:]
      : Self.loadSummaryTitlesFromSQLite(
        at: antigravityURL.appending(path: "conversation_summaries.db"),
        conversationIDs: idsMissingName
      )

    var conversations: [ActiveConversation] = []
    conversations.reserveCapacity(selectedCandidates.count)

    for candidate in selectedCandidates {
      guard
        let lines = try? Self.tailLines(at: candidate.transcriptURL, maxBytes: Self.tailByteCount)
      else {
        continue
      }
      let snapshot = AntigravityTranscriptParser.parse(lines: lines)
      guard snapshot.contextTokens != nil || snapshot.compaction.isCompacted else {
        continue
      }

      let resolvedName =
        SessionNameSanitizer.clean(namesByCID[candidate.cid])
        ?? SessionNameSanitizer.clean(titlesByCID[candidate.cid])
        ?? String(candidate.cid.prefix(8))

      conversations.append(
        ActiveConversation(
          id: "antigravity:\(candidate.cid)",
          name: resolvedName,
          providerID: "antigravity",
          providerName: "Antigravity",
          icon: .symbol("sparkle"),
          tint: .blue,
          contextTokens: snapshot.contextTokens,
          modelContextWindow: ActiveConversation.antigravityContextWindow,
          compaction: snapshot.compaction
        )
      )
    }

    return conversations
  }

  private static func antigravityTranscript(in conversationDir: URL) -> (URL, Date)? {
    let logsDir = conversationDir.appending(
      path: ".system_generated/logs",
      directoryHint: .isDirectory
    )
    for filename in ["transcript.jsonl", "transcript_full.jsonl"] {
      let candidate = logsDir.appending(path: filename)
      guard
        let values = try? candidate.resourceValues(
          forKeys: [.isRegularFileKey, .contentModificationDateKey]
        ),
        values.isRegularFile == true,
        let mtime = values.contentModificationDate
      else {
        continue
      }
      return (candidate, mtime)
    }
    return nil
  }

  private static func loadRecordedContextWindow(
    for sessionId: String,
    in cacheDirectory: URL,
    decoder: JSONDecoder
  ) -> Int? {
    let fileURL = cacheDirectory.appending(path: "\(sessionId).json")
    guard
      let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
      values.isRegularFile == true,
      let size = values.fileSize,
      size <= maxRegistryFileBytes,
      let data = try? Data(contentsOf: fileURL),
      let record = try? decoder.decode(ContextWindowRecord.self, from: data),
      let window = record.window,
      window >= minValidContextWindow,
      window <= maxValidContextWindow
    else {
      return nil
    }
    return window
  }

  private static func loadAntigravityNames(at url: URL) -> [String: String] {
    guard
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
      values.isRegularFile == true,
      let size = values.fileSize,
      size <= maxNamesFileBytes,
      let data = try? Data(contentsOf: url),
      let mapping = try? JSONDecoder().decode([String: String].self, from: data)
    else {
      return [:]
    }
    return mapping
  }

  /// Lê títulos opcionais de `conversation_summaries.db` usando URI somente-leitura com `immutable=1`
  /// (especificação: https://www.sqlite.org/uri.html), impedindo criação de arquivos `-wal` ou `-shm`.
  private static func loadSummaryTitlesFromSQLite(
    at dbURL: URL,
    conversationIDs: [String]
  ) -> [String: String] {
    guard
      !conversationIDs.isEmpty,
      let values = try? dbURL.resourceValues(forKeys: [.isRegularFileKey]),
      values.isRegularFile == true,
      hasSQLiteHeader(at: dbURL)
    else {
      return [:]
    }

    let uri = makeImmutableSQLiteURI(forPath: dbURL.path)
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
    guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else {
      if let db {
        sqlite3_close_v2(db)
      }
      return [:]
    }
    defer { sqlite3_close_v2(db) }

    sqlite3_busy_timeout(db, 250)

    let placeholders = Array(repeating: "?", count: conversationIDs.count).joined(separator: ",")
    let query =
      "SELECT conversation_id, title FROM conversation_summaries WHERE conversation_id IN (\(placeholders));"

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
      return [:]
    }
    defer { sqlite3_finalize(statement) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, cid) in conversationIDs.enumerated() {
      guard sqlite3_bind_text(statement, Int32(offset + 1), cid, -1, transient) == SQLITE_OK else {
        return [:]
      }
    }

    var titles: [String: String] = [:]
    while sqlite3_step(statement) == SQLITE_ROW {
      guard
        let rawCID = sqlite3_column_text(statement, 0),
        let rawTitle = sqlite3_column_text(statement, 1)
      else {
        continue
      }
      let cid = String(cString: rawCID)
      let title = String(cString: rawTitle)
      if let cleanTitle = SessionNameSanitizer.clean(title) {
        titles[cid] = cleanTitle
      }
    }

    return titles
  }

  private static func hasSQLiteHeader(at url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      return false
    }
    defer { try? handle.close() }
    guard let header = try? handle.read(upToCount: 16) else {
      return false
    }
    return header == Data("SQLite format 3\0".utf8)
  }

  private static func makeImmutableSQLiteURI(forPath path: String) -> String {
    let escaped =
      path
      .replacingOccurrences(of: "%", with: "%25")
      .replacingOccurrences(of: "?", with: "%3f")
      .replacingOccurrences(of: "#", with: "%23")
    return "file:\(escaped)?mode=ro&immutable=1"
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
