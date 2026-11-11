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
          "BRAIN_PANEL_CLAUDE_CONTEXT_CACHE_DIR": canaryToken,
          "BRAIN_PANEL_ANTIGRAVITY_DIR": canaryDocument,
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

    // 4. Transcripts JSONL (Claude e Antigravity) contendo o canário no conteúdo da conversa
    let transcriptLines: [Substring] = [
      Substring(
        #"{"type":"user","message":{"content":"Segredo \#(canaryToken) doc \#(canaryDocument)"}}"#
      ),
      #"{"type":"assistant","message":{"usage":{"input_tokens":1000,"cache_read_input_tokens":500,"cache_creation_input_tokens":0}}}"#,
    ]
    let claudeSnapshot = ClaudeTranscriptParser.parse(lines: transcriptLines)
    XCTAssertEqual(claudeSnapshot.contextTokens, 1_500)
    XCTAssertNil(claudeSnapshot.sessionName)

    let agyLines: [Substring] = [
      Substring(
        #"{"type":"USER_INPUT","content":"Segredo \#(canaryToken) doc \#(canaryDocument)"}"#
      ),
      Substring(
        #"{"type":"PLANNER_RESPONSE","content":"\#(canaryToken)","thinking":"\#(canaryDocument)","input_tokens":2000,"cache_read_tokens":3000}"#
      ),
    ]
    let agySnapshot = AntigravityTranscriptParser.parse(lines: agyLines)
    XCTAssertEqual(agySnapshot.contextTokens, 5_000)

    // 5. Estado do Brain: text de brain-mail nunca é decodificado e dados flexograv nunca vazam
    let mailPayload = Data(
      #"{"id":"m1","from":"painel-dev","to":"painel-lead","at":1762815000,"text":"\#(canaryToken) \#(canaryDocument)"}"#
        .utf8
    )
    let flexogravPending = Data(
      #"{"name":"flexograv-lead","project":"flexograv","transcript":"/Users/exemplo/flexograv/t.jsonl","at":1762819100,"text":"\#(canaryToken) \#(canaryDocument)"}"#
        .utf8
    )
    let waitingState = BrainWaitingEvaluator.evaluate(
      pendingCandidates: [
        .init(jsonData: flexogravPending, transcriptModifiedAt: nil)
      ],
      mailboxes: [
        .init(recipient: "painel-lead", messagePayloads: [mailPayload])
      ],
      openSessionNames: ["painel-lead"],
      now: clock.now()
    )
    XCTAssertEqual(waitingState.pendingPrompts.count, 1)
    XCTAssertNil(waitingState.pendingPrompts.first?.text)
    assertNoCanary(in: String(describing: waitingState))

    let flexogravTicket = Data(
      #"{"pid":99,"project":"flexograv-erp","role":"dev","cmd":"\#(canaryToken)","commit":"\#(canaryDocument)","queued":1762819100,"started":1762819110,"folder":"/Documents/flexograv"}"#
        .utf8
    )
    let flexogravRun = Substring(
      #"{"kind":"run","queue_version":4,"project":"flexograv-erp","dir":"/Documents/flexograv","type":"ci","role":"dev","cmd":"\#(canaryToken)","commit":"\#(canaryDocument)","queued":1762819000,"start":1762819010,"end":1762819150,"exit":0,"interrupted":false}"#
    )
    let flexogravAlert = Substring(
      #"{"at":1762819150,"project":"flexograv-erp","cmd":"\#(canaryToken)","alarm":"\#(canaryDocument)"}"#
    )
    let ciState = BrainCIQueueEvaluator.evaluate(
      inputs: .init(
        versionData: Data(#"{"version":4}"#.utf8),
        pausedData: nil,
        modeData: nil,
        vmNowData: nil,
        ticketPayloads: [(id: "t1", data: flexogravTicket)],
        runLines: [flexogravRun],
        alertLines: [flexogravAlert]
      ),
      now: clock.now(),
      isProcessAlive: { _ in true }
    )
    assertNoCanary(in: String(describing: ciState))

    // 6. Exceção inesperada externa contendo o canário passando pela UsageStore e pelo logger
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
        ),
        .failure(RawExternalFailure(message: "Falha stale \(canaryToken) \(canaryDocument)")),
      ]
    )

    let failingBrainCollector = StubBrainStateCollector(
      results: [
        .failure(RawExternalFailure(message: "Falha brain \(canaryToken) \(canaryDocument)"))
      ]
    )

    let store = UsageStore(
      collectors: [failingCollector, succeedingCollector],
      conversationCollector: nil,
      brainCollector: failingBrainCollector,
      clock: clock,
      logger: logger,
      startPeriodicRefresh: false
    )
    await store.refresh()
    await store.refresh()

    for provider in store.providers {
      if let reason = provider.unavailableReason {
        assertNoCanary(in: reason)
      }
      if let staleReason = provider.staleReason {
        assertNoCanary(in: staleReason)
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
