import Foundation
import XCTest

@testable import BrainPanel

@MainActor
final class SecurityCanaryTests: XCTestCase {
  private let canaryToken = "FAKE-CANARIO-TOKEN-99887766"
  private let canaryDocument = "FAKE-CANARIO-CPF-123.456.789-00"

  func testCanaryNeverLeaksToUserErrorsOrStructuredLogsOnFailureAndSuccess() async {
    let clock = TestClock()
    let logSink = InMemoryLogSink()
    let logger = StructuredLogger(clock: clock, sink: logSink)

    // 1. Falha de configuração contendo canário no valor da variável
    XCTAssertThrowsError(
      try AppConfig.parse(
        environment: [
          "BRAIN_PANEL_MODE": canaryToken,
          "BRAIN_PANEL_CLAUDE_SESSIONS_DIR": canaryDocument,
        ],
        defaultHomeDirectory: URL(filePath: "/Users/teste"),
        defaultAppSupportRoot: URL(filePath: "/Users/teste/Library/Application Support"),
        defaultTemporaryRoot: URL(filePath: "/tmp"),
        bundleIdentifier: "com.h3zord.BrainPanel"
      )
    ) { error in
      let normalized = ErrorHandler.normalize(error)
      assertNoCanary(in: normalized.userMessage)
      logger.error(
        event: "boot_failed",
        refreshID: "canary-boot",
        errorCode: normalized.code,
        fields: [.setting: normalized.safeSettingName ?? ""]
      )
    }

    // 2. Falha de parsing de telas contendo o canário
    let brokenClaudeScreen = "Erro bruto \(canaryToken) \(canaryDocument)"
    XCTAssertThrowsError(
      try ClaudeUsageParser.makeUsage(from: brokenClaudeScreen, now: clock.now())
    ) { error in
      let normalized = ErrorHandler.normalize(error)
      assertNoCanary(in: normalized.userMessage)
    }

    // 3. Sucesso de parsing de telas contendo o canário em texto periférico do terminal
    let validClaudeWithCanary = """
      Account \(canaryDocument) \(canaryToken)
      Claude Max
      Current session ██ 25% used Resets 11pm (UTC)
      Current week (all models) █ 10% used Resets Nov 14 at 3am (UTC)
      """
    let parsedUsage = try? ClaudeUsageParser.makeUsage(from: validClaudeWithCanary, now: clock.now())
    XCTAssertNotNil(parsedUsage)

    // 4. Transcript JSONL contendo o canário no conteúdo da conversa
    let transcriptLines: [Substring] = [
      Substring(
        #"{"type":"user","message":{"content":"Segredo \#(canaryToken) doc \#(canaryDocument)"}}"#
      ),
      #"{"type":"assistant","message":{"usage":{"input_tokens":1000,"cache_read_input_tokens":500,"cache_creation_input_tokens":0}}}"#,
    ]
    let tokens = ClaudeTranscriptParser.contextTokens(in: transcriptLines)
    XCTAssertEqual(tokens, 1_500)

    // 5. Exceção inesperada externa contendo o canário passando pela UsageStore e pelo logger
    struct RawExternalFailure: Error, LocalizedError {
      let message: String
      var errorDescription: String? { message }
    }

    let failingCollector = StubUsageCollector(
      providerID: "claude",
      results: [.failure(RawExternalFailure(message: "Token vazado \(canaryToken) \(canaryDocument)"))]
    )
    let succeedingCollector = StubUsageCollector(
      providerID: "gemini",
      results: [
        .success(
          ProviderUsage(
            id: "gemini",
            name: "Gemini",
            plan: "Google AI Pro",
            icon: .symbol("sparkle"),
            tint: .blue,
            sessionState: .active,
            limits: []
          )
        )
      ]
    )

    let store = UsageStore(
      collectors: [failingCollector, succeedingCollector],
      conversationCollector: nil,
      clock: clock,
      logger: logger,
      startPeriodicRefresh: false
    )
    await store.refresh()

    for provider in store.providers {
      if let reason = provider.unavailableReason {
        assertNoCanary(in: reason)
      }
    }

    for line in logSink.lines {
      assertNoCanary(in: line)
    }
  }

  private func assertNoCanary(in text: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(text.contains("FAKE-CANARIO"), "Canário vazou em: \(text)", file: file, line: line)
    XCTAssertFalse(text.contains(canaryToken), "Token canário vazou em: \(text)", file: file, line: line)
    XCTAssertFalse(text.contains(canaryDocument), "CPF canário vazou em: \(text)", file: file, line: line)
  }
}
