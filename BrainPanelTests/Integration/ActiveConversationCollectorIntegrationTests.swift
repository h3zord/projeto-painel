import Darwin
import Foundation
import XCTest

@testable import BrainPanel

final class ActiveConversationCollectorIntegrationTests: XCTestCase {
  func testCollectsLiveClaudeSessionsFromIsolatedLocalTmpDirectories() async throws {
    let tempRoot = try makeIsolatedTmpDirectory()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let sessionsDir = tempRoot.appending(path: "sessions", directoryHint: .isDirectory)
    let projectsDir = tempRoot.appending(path: "projects", directoryHint: .isDirectory)
    let projectA = projectsDir.appending(path: "proj-a", directoryHint: .isDirectory)
    let projectB = projectsDir.appending(path: "proj-b", directoryHint: .isDirectory)

    try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)

    let currentPID = getpid()

    // Sessão viva 1 (com nome explícito)
    try writeJSON(
      #"{"pid":\#(currentPID),"sessionId":"sess-lead","name":"painel-lead"}"#,
      to: sessionsDir.appending(path: "01-lead.json")
    )
    try writeJSON(
      """
      {"type":"assistant","message":{"usage":{"input_tokens":5000,"cache_read_input_tokens":310000,"cache_creation_input_tokens":0}}}
      """,
      to: projectA.appending(path: "sess-lead.jsonl")
    )

    // Sessão viva 2 (sem nome -> fallback + leitura em tail parcial descartando 1ª linha truncada)
    try writeJSON(
      #"{"pid":"\#(currentPID)","sessionId":"sess-dev-12345678","name":"   "}"#,
      to: sessionsDir.appending(path: "02-dev.json")
    )
    let paddingLine = String(repeating: "x", count: 2_048)
    let devTranscript = """
      {"type":"user","padding":"\(paddingLine)"}
      {"type":"assistant","message":{"usage":{"input_tokens":2000,"cache_read_input_tokens":80000,"cache_creation_input_tokens":500}}}
      """
    let devTranscriptURL = projectB.appending(path: "sess-dev-12345678.jsonl")
    try writeJSON(devTranscript, to: devTranscriptURL)

    // Sessão morta (PID inexistente filtrado pelo predicado) e tentativa de traversal "../escape"
    try writeJSON(
      #"{"pid":999991,"sessionId":"sess-dead","name":"morta"}"#,
      to: sessionsDir.appending(path: "03-dead.json")
    )
    try writeJSON(
      #"{"pid":\#(currentPID),"sessionId":"../escape","name":"invalida"}"#,
      to: sessionsDir.appending(path: "04-traversal.json")
    )

    let collector = ActiveConversationCollector(
      claudeSessionsURL: sessionsDir,
      claudeProjectsURL: projectsDir,
      isProcessAlive: { pid in pid == currentPID }
    )

    let conversations = try await collector.fetchActiveConversations()
    XCTAssertEqual(conversations.count, 2)
    XCTAssertEqual(conversations[0].name, "painel-lead")
    XCTAssertEqual(conversations[0].contextTokens, 315_000)
    XCTAssertEqual(conversations[0].statusLevel, .softWarning)

    XCTAssertEqual(conversations[1].name, "sem nome sess-dev")
    XCTAssertEqual(conversations[1].contextTokens, 82_500)
    XCTAssertEqual(conversations[1].statusLevel, .normal)

    // Confere leitura tail com limite menor que o tamanho total do arquivo
    let tailTokens = try ActiveConversationCollector.contextTokensOfTranscript(
      at: devTranscriptURL,
      maxTailBytes: 512
    )
    XCTAssertEqual(tailTokens, 82_500)
  }

  func testReturnsEmptyWhenClaudeDirectoriesDoNotExistYet() async throws {
    let tempRoot = try makeIsolatedTmpDirectory()
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let collector = ActiveConversationCollector(
      claudeSessionsURL: tempRoot.appending(path: "inexistente-sessions", directoryHint: .isDirectory),
      claudeProjectsURL: tempRoot.appending(path: "inexistente-projects", directoryHint: .isDirectory),
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
      try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedSessionsDir.path)
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
      .appending(path: "local/tmp/integration-sessions-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func writeJSON(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
  }
}
