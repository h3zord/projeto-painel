import Darwin
import Foundation
import SQLite3
import XCTest

@testable import BrainPanel

final class ActiveConversationCollectorIntegrationTests: XCTestCase {
  private struct FixedIntegrationClock: Clock {
    let fixedDate: Date

    func now() -> Date {
      fixedDate
    }

    func sleep(for _: Duration) async throws {}
  }

  func testCollectsClaudeAndAntigravitySessionsWithContextWindowsNamesAndReadOnlySQLite() async throws {
    let tempRoot = try makeIsolatedTmpDirectory()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let fixedNow = Date(timeIntervalSince1970: 1_762_848_000)
    let clock = FixedIntegrationClock(fixedDate: fixedNow)

    let sessionsDir = tempRoot.appending(path: "sessions", directoryHint: .isDirectory)
    let projectsDir = tempRoot.appending(path: "projects", directoryHint: .isDirectory)
    let contextCacheDir = tempRoot.appending(path: "claude-context", directoryHint: .isDirectory)
    let antigravityDir = tempRoot.appending(path: "antigravity-cli", directoryHint: .isDirectory)
    let brainSessionsDir = tempRoot.appending(path: "brain-sessions", directoryHint: .isDirectory)

    let projectA = projectsDir.appending(path: "proj-a", directoryHint: .isDirectory)
    let projectB = projectsDir.appending(path: "proj-b", directoryHint: .isDirectory)

    for folder in [sessionsDir, projectA, projectB, contextCacheDir, antigravityDir, brainSessionsDir] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    let currentPID = getpid()

    // 1. Sessão Claude viva com janela real registrada em claude-context (200_000 -> 150_000 = 75% softWarning)
    try writeJSON(
      #"{"pid":\#(currentPID),"sessionId":"sess-lead","name":"painel-lead"}"#,
      to: sessionsDir.appending(path: "01-lead.json")
    )
    try writeJSON(
      #"{"window":200000}"#,
      to: contextCacheDir.appending(path: "sess-lead.json")
    )
    try writeJSON(
      """
      {"type":"assistant","message":{"usage":{"input_tokens":5000,"cache_read_input_tokens":145000,"cache_creation_input_tokens":0}}}
      """,
      to: projectA.appending(path: "sess-lead.jsonl")
    )

    // 2. Sessão Claude viva sem janela registrada (janela presumida 1M) e sem nome no JSON (fallback customTitle + tail parcial)
    try writeJSON(
      #"{"pid":"\#(currentPID)","sessionId":"sess-dev-12345678","name":"   "}"#,
      to: sessionsDir.appending(path: "02-dev.json")
    )
    let paddingLine = String(repeating: "x", count: 2_048)
    let devTranscript = """
      {"type":"user","padding":"\(paddingLine)"}
      {"type":"custom-title","customTitle":"painel-claude-dev"}
      {"type":"assistant","message":{"usage":{"input_tokens":2000,"cache_read_input_tokens":80000,"cache_creation_input_tokens":500}}}
      """
    let devTranscriptURL = projectB.appending(path: "sess-dev-12345678.jsonl")
    try writeJSON(devTranscript, to: devTranscriptURL)

    // 3. Sessão Claude viva recém-compactada (compact_boundary após 420k tokens -> normal, isCompacted)
    try writeJSON(
      #"{"pid":\#(currentPID),"sessionId":"sess-compacted","name":"painel-compact"}"#,
      to: sessionsDir.appending(path: "03-compacted.json")
    )
    try writeJSON(
      """
      {"type":"assistant","message":{"usage":{"input_tokens":20000,"cache_read_input_tokens":400000,"cache_creation_input_tokens":0}}}
      {"type":"system","subtype":"compact_boundary","timestamp":"2026-11-11T07:50:00Z"}
      """,
      to: projectA.appending(path: "sess-compacted.jsonl")
    )

    // Sessão morta e tentativa de traversal "../escape"
    try writeJSON(
      #"{"pid":999991,"sessionId":"sess-dead","name":"morta"}"#,
      to: sessionsDir.appending(path: "04-dead.json")
    )
    try writeJSON(
      #"{"pid":\#(currentPID),"sessionId":"../escape","name":"invalida"}"#,
      to: sessionsDir.appending(path: "05-traversal.json")
    )

    // Mapa de nomes do brain-sessions para o Antigravity
    try writeJSON(
      #"{"cid-agy-named-1111":"painel-agy-dev"}"#,
      to: brainSessionsDir.appending(path: "antigravity-names.json")
    )

    // Banco SQLite real (em modo WAL, fechado sem -wal/-shm residuais) para testar leitura estritamente read-only sem criar arquivos
    let dbURL = antigravityDir.appending(path: "conversation_summaries.db")
    try createWALDatabase(
      at: dbURL,
      rows: [
        ("cid-agy-named-1111", "Titulo Ignorado Pelo Brain Sessions"),
        ("cid-agy-dbtitle-2222", "Resumo no SQLite"),
      ]
    )
    // O libsqlite3 do macOS usa PERSIST_WAL=1 por padrão; removemos -wal/-shm após o checkpoint
    // para provar que a leitura do coletor (immutable=1) não recria arquivos auxiliares no disco.
    try? FileManager.default.removeItem(atPath: dbURL.path + "-wal")
    try? FileManager.default.removeItem(atPath: dbURL.path + "-shm")
    let antigravityFilesBefore = try Set(
      FileManager.default.contentsOfDirectory(atPath: antigravityDir.path)
    )
    XCTAssertEqual(antigravityFilesBefore, ["conversation_summaries.db"])

    // 4. Conversa Antigravity recente com nome em antigravity-names.json (850_000 / 1_048_576 = 81% -> hardLimit)
    try writeAntigravityTranscript(
      in: antigravityDir,
      cid: "cid-agy-named-1111",
      filename: "transcript.jsonl",
      content: """
        {"type":"PLANNER_RESPONSE","input_tokens":50000,"cache_read_tokens":800000}
        """,
      modificationDate: fixedNow.addingTimeInterval(-300)
    )

    // 5. Conversa Antigravity recente usando fallback transcript_full.jsonl, CHECKPOINT e título do SQLite
    try writeAntigravityTranscript(
      in: antigravityDir,
      cid: "cid-agy-dbtitle-2222",
      filename: "transcript_full.jsonl",
      content: """
        {"type":"PLANNER_RESPONSE","input_tokens":10000,"cache_read_tokens":900000}
        {"type":"CHECKPOINT","created_at":"2026-11-11T07:55:00Z"}
        """,
      modificationDate: fixedNow.addingTimeInterval(-120)
    )

    // 6. Conversa Antigravity recente sem nome no JSON nem no SQLite -> fallback cid.prefix(8)
    try writeAntigravityTranscript(
      in: antigravityDir,
      cid: "abcdef12-9999-0000",
      filename: "transcript.jsonl",
      content: """
        {"type":"PLANNER_RESPONSE","input_tokens":5000,"cache_read_tokens":95000}
        """,
      modificationDate: fixedNow.addingTimeInterval(-600)
    )

    // 7. Conversa Antigravity expirada (modificada há 3h > janela de 2h do TestClock) -> deve ser ignorada
    try writeAntigravityTranscript(
      in: antigravityDir,
      cid: "cid-agy-expired-4444",
      filename: "transcript.jsonl",
      content: """
        {"type":"PLANNER_RESPONSE","input_tokens":50000,"cache_read_tokens":900000}
        """,
      modificationDate: fixedNow.addingTimeInterval(-3 * 3_600)
    )

    let collector = ActiveConversationCollector(
      claudeSessionsURL: sessionsDir,
      claudeProjectsURL: projectsDir,
      claudeContextCacheURL: contextCacheDir,
      antigravityURL: antigravityDir,
      brainSessionsStateURL: brainSessionsDir,
      clock: clock,
      antigravityActiveWindowSeconds: 2 * 3_600,
      isProcessAlive: { pid in pid == currentPID }
    )

    let conversations = try await collector.fetchActiveConversations()
    XCTAssertEqual(conversations.count, 6)

    // Ordenação esperada por ocupação percentual decrescente, depois compactadas:
    // 0: painel-agy-dev (850k / 1_048_576 = 81%, hardLimit)
    // 1: painel-lead (150k / 200_000 = 75%, softWarning, janela registrada)
    // 2: abcdef12 (100k / 1_048_576 = 9%, normal)
    // 3: painel-claude-dev (82.5k / 1_000_000 = 8%, normal, janela presumida)
    // 4 & 5: compactadas (Resumo no SQLite às 07:55Z, painel-compact às 07:50Z)
    XCTAssertEqual(
      conversations.map(\.name),
      [
        "painel-agy-dev",
        "painel-lead",
        "abcdef12",
        "painel-claude-dev",
        "Resumo no SQLite",
        "painel-compact",
      ]
    )

    XCTAssertEqual(conversations[0].providerID, "antigravity")
    XCTAssertEqual(conversations[0].statusLevel, .hardLimit)
    XCTAssertFalse(conversations[0].isWindowPresumed)

    XCTAssertEqual(conversations[1].providerID, "claude")
    XCTAssertEqual(conversations[1].statusLevel, .softWarning)
    XCTAssertEqual(conversations[1].effectiveContextWindow, 200_000)
    XCTAssertFalse(conversations[1].isWindowPresumed)

    XCTAssertEqual(conversations[3].effectiveContextWindow, 1_000_000)
    XCTAssertTrue(conversations[3].isWindowPresumed)

    XCTAssertTrue(conversations[4].isCompacted)
    XCTAssertEqual(conversations[4].statusLevel, .normal)
    XCTAssertTrue(conversations[5].isCompacted)
    XCTAssertEqual(conversations[5].statusLevel, .normal)

    // Garante que inspecionar o SQLite não criou arquivos -wal ou -shm em antigravityDir
    let antigravityFilesAfter = try Set(
      FileManager.default.contentsOfDirectory(atPath: antigravityDir.path)
    )
    XCTAssertEqual(
      antigravityFilesAfter,
      ["conversation_summaries.db", "brain"],
      "A leitura do SQLite não pode criar arquivos -wal, -shm ou -journal"
    )

    // Confere leitura tail com limite menor que o tamanho total do arquivo
    let tailTokens = try ActiveConversationCollector.contextTokensOfTranscript(
      at: devTranscriptURL,
      maxTailBytes: 512
    )
    XCTAssertEqual(tailTokens, 82_500)
  }

  func testEnforcesMaxAntigravityConversationsCapAndHandlesCorruptedOptionalMetadataGracefully()
    async throws
  {
    let tempRoot = try makeIsolatedTmpDirectory()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let fixedNow = Date(timeIntervalSince1970: 1_762_848_000)
    let clock = FixedIntegrationClock(fixedDate: fixedNow)

    let sessionsDir = tempRoot.appending(path: "sessions", directoryHint: .isDirectory)
    let projectsDir = tempRoot.appending(path: "projects", directoryHint: .isDirectory)
    let contextCacheDir = tempRoot.appending(path: "claude-context", directoryHint: .isDirectory)
    let antigravityDir = tempRoot.appending(path: "antigravity-cli", directoryHint: .isDirectory)
    let brainSessionsDir = tempRoot.appending(path: "brain-sessions", directoryHint: .isDirectory)

    for folder in [sessionsDir, projectsDir, contextCacheDir, antigravityDir, brainSessionsDir] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    // Metadados opcionais malformados não podem derrubar a coleta
    try writeJSON("json-quebrado", to: brainSessionsDir.appending(path: "antigravity-names.json"))
    try writeJSON("sqlite-invalido", to: antigravityDir.appending(path: "conversation_summaries.db"))

    for index in 1...4 {
      try writeAntigravityTranscript(
        in: antigravityDir,
        cid: "cid-000\(index)-aaaa",
        filename: "transcript.jsonl",
        content: """
          {"type":"PLANNER_RESPONSE","input_tokens":10000,"cache_read_tokens":\(index * 100_000)}
          """,
        modificationDate: fixedNow.addingTimeInterval(TimeInterval(-index * 60))
      )
    }

    let collector = ActiveConversationCollector(
      claudeSessionsURL: sessionsDir,
      claudeProjectsURL: projectsDir,
      claudeContextCacheURL: contextCacheDir,
      antigravityURL: antigravityDir,
      brainSessionsStateURL: brainSessionsDir,
      clock: clock,
      antigravityActiveWindowSeconds: 2 * 3_600,
      maxAntigravityConversations: 2,
      isProcessAlive: { _ in false }
    )

    let conversations = try await collector.fetchActiveConversations()
    XCTAssertEqual(conversations.count, 2)
    // Os 2 mais recentes por mtime são cid-0001 (110k) e cid-0002 (210k); na priorização cid-0002 vem primeiro
    XCTAssertEqual(conversations.map(\.name), ["cid-0002", "cid-0001"])
  }

  func testReturnsEmptyWhenClaudeAndAntigravityDirectoriesDoNotExistYet() async throws {
    let tempRoot = try makeIsolatedTmpDirectory()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let collector = ActiveConversationCollector(
      claudeSessionsURL: tempRoot.appending(path: "inexistente-sessions", directoryHint: .isDirectory),
      claudeProjectsURL: tempRoot.appending(path: "inexistente-projects", directoryHint: .isDirectory),
      claudeContextCacheURL: tempRoot.appending(path: "inexistente-cache", directoryHint: .isDirectory),
      antigravityURL: tempRoot.appending(path: "inexistente-agy", directoryHint: .isDirectory),
      brainSessionsStateURL: tempRoot.appending(path: "inexistente-state", directoryHint: .isDirectory),
      isProcessAlive: { _ in true }
    )

    let conversations = try await collector.fetchActiveConversations()
    XCTAssertTrue(conversations.isEmpty)
  }

  func testThrowsTranscriptReadFailedWhenSessionsOrProjectsDirectoryCannotBeRead() async throws {
    let tempRoot = try makeIsolatedTmpDirectory()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let validSessionsDir = tempRoot.appending(path: "sessions", directoryHint: .isDirectory)
    let validProjectsDir = tempRoot.appending(path: "projects", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: validSessionsDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: validProjectsDir, withIntermediateDirectories: true)

    let regularFileInsteadOfDir = tempRoot.appending(path: "arquivo-regular.txt")
    try writeJSON("nao e diretorio", to: regularFileInsteadOfDir)

    let badSessionsCollector = ActiveConversationCollector(
      claudeSessionsURL: regularFileInsteadOfDir,
      claudeProjectsURL: validProjectsDir,
      isProcessAlive: { _ in true }
    )
    await assertThrowsTranscriptReadFailed {
      _ = try await badSessionsCollector.fetchActiveConversations()
    }

    let badProjectsCollector = ActiveConversationCollector(
      claudeSessionsURL: validSessionsDir,
      claudeProjectsURL: regularFileInsteadOfDir,
      isProcessAlive: { _ in true }
    )
    await assertThrowsTranscriptReadFailed {
      _ = try await badProjectsCollector.fetchActiveConversations()
    }

    if geteuid() != 0 {
      let lockedSessionsDir = tempRoot.appending(path: "locked-sessions", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: lockedSessionsDir, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o000], ofItemAtPath: lockedSessionsDir.path)
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: lockedSessionsDir.path)
      }

      let lockedCollector = ActiveConversationCollector(
        claudeSessionsURL: lockedSessionsDir,
        claudeProjectsURL: validProjectsDir,
        isProcessAlive: { _ in true }
      )
      await assertThrowsTranscriptReadFailed {
        _ = try await lockedCollector.fetchActiveConversations()
      }
    }
  }

  private func assertThrowsTranscriptReadFailed(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("Esperava AppError.transcriptReadFailed()", file: file, line: line)
    } catch let appError as AppError {
      XCTAssertEqual(appError.code, .transcriptReadFailed, file: file, line: line)
    } catch {
      XCTFail("Erro inesperado: \(error)", file: file, line: line)
    }
  }

  private func makeIsolatedTmpDirectory() throws -> URL {
    let repoRoot = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let dir =
      repoRoot
      .appending(
        path: "local/tmp/integration-sessions-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func writeJSON(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
  }

  private func writeAntigravityTranscript(
    in antigravityDir: URL,
    cid: String,
    filename: String,
    content: String,
    modificationDate: Date
  ) throws {
    let logsDir =
      antigravityDir
      .appending(path: "brain", directoryHint: .isDirectory)
      .appending(path: cid, directoryHint: .isDirectory)
      .appending(path: ".system_generated/logs", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let fileURL = logsDir.appending(path: filename)
    try writeJSON(content, to: fileURL)
    try FileManager.default.setAttributes(
      [.modificationDate: modificationDate],
      ofItemAtPath: fileURL.path
    )
  }

  private func createWALDatabase(at dbURL: URL, rows: [(String, String)]) throws {
    var db: OpaquePointer?
    guard
      sqlite3_open_v2(
        dbURL.path,
        &db,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
        nil
      ) == SQLITE_OK,
      let db
    else {
      XCTFail("Falha ao criar SQLite de teste em \(dbURL.path)")
      return
    }
    defer { sqlite3_close(db) }

    XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil), SQLITE_OK)
    XCTAssertEqual(
      sqlite3_exec(
        db,
        "CREATE TABLE conversation_summaries (conversation_id TEXT PRIMARY KEY, title TEXT, workspace_uris TEXT);",
        nil,
        nil,
        nil
      ),
      SQLITE_OK
    )

    var stmt: OpaquePointer?
    let sql =
      "INSERT INTO conversation_summaries (conversation_id, title, workspace_uris) VALUES (?, ?, '[]');"
    XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
    defer { sqlite3_finalize(stmt) }

    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (cid, title) in rows {
      sqlite3_reset(stmt)
      sqlite3_bind_text(stmt, 1, cid, -1, transient)
      sqlite3_bind_text(stmt, 2, title, -1, transient)
      XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
    }
    XCTAssertEqual(sqlite3_exec(db, "PRAGMA wal_checkpoint(FULL);", nil, nil, nil), SQLITE_OK)
  }
}
