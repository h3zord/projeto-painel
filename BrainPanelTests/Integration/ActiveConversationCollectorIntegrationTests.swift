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
    let tailTokens = ActiveConversationCollector.contextTokensOfTranscript(
      at: devTranscriptURL,
      maxTailBytes: 512
    )
    XCTAssertEqual(tailTokens, 82_500)
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
