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
          "BRAIN_PANEL_BRAIN_PAGES_URL": "http://\(canaryToken):4780/\(canaryDocument)",
          "BRAIN_PANEL_NOTIFICATIONS_ENABLED": canaryToken,
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
      #"{"name":"flexograv-lead","project":"flexograv-\#(canaryToken)","transcript":"/Users/exemplo/flexograv/t.jsonl","at":1762819100,"text":"http://127.0.0.1:4780/flexograv/doc-\#(canaryToken) \#(canaryDocument)"}"#
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
    XCTAssertNil(waitingState.pendingPrompts.first?.project)
    XCTAssertNil(waitingState.pendingPrompts.first?.text)
    assertNoCanary(in: String(describing: waitingState))
    if let firstPrompt = waitingState.pendingPrompts.first,
      let resolvedURL = BrainPagesNavigator.resolveDestination(
        for: firstPrompt,
        baseURL: AppConfig.defaultBrainPagesURL
      )
    {
      assertNoCanary(in: resolvedURL.absoluteString)
    }
    let directCanaryCorporatePrompt = PendingPrompt(
      sessionKey: "flexograv-lead",
      project: "flexograv-\(canaryToken)",
      askedAt: clock.now(),
      text: "http://127.0.0.1:4780/flexograv/doc-\(canaryToken)",
      isExplicit: true,
      hasButton: false
    )
    if let resolvedDirect = BrainPagesNavigator.resolveDestination(
      for: directCanaryCorporatePrompt,
      baseURL: AppConfig.defaultBrainPagesURL
    ) {
      assertNoCanary(in: resolvedDirect.absoluteString)
    }

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
        .success(
          BrainSnapshot(
            waiting: .loaded(
              WaitingState(
                pendingPrompts: [
                  PendingPrompt(
                    sessionKey: "flexograv-lead",
                    project: "flexograv-\(canaryToken)",
                    askedAt: clock.now(),
                    text: "Segredo \(canaryToken) \(canaryDocument)",
                    isExplicit: true,
                    hasButton: true
                  ),
                  PendingPrompt(
                    sessionKey: "painel-lead",
                    project: "projeto-painel",
                    askedAt: clock.now(),
                    text: "Pergunta com \(canaryToken) \(canaryDocument)",
                    isExplicit: true,
                    hasButton: true
                  ),
                ],
                stuckMail: [
                  StuckMailbox(
                    recipient: "flexograv-dev",
                    unreadCount: 1,
                    oldestMessageAt: clock.now().addingTimeInterval(-3_600),
                    senders: ["remetente-\(canaryToken)"]
                  )
                ],
                closedMail: []
              )
            ),
            ciQueue: .loaded(.empty),
            healthAndBackup: .loaded(
              HealthAndBackupState(
                doctorFailures: [
                  DoctorFinding(
                    key: "FAIL 99",
                    severity: .fail,
                    message: "Detalhe sensível \(canaryToken) \(canaryDocument)"
                  )
                ],
                doctorWarnings: [],
                doctorCheckedAt: clock.now(),
                testSuite: nil,
                syncStatus: nil,
                backupStatus: BackupStatus(
                  isPassing: false,
                  isOverdue: true,
                  reason: "Falha \(canaryToken) \(canaryDocument)",
                  completedAt: nil,
                  snapshotID: nil,
                  addedBytes: nil,
                  filesCount: nil
                ),
                liveBackupProgress: LiveBackupProgress(
                  phase: "upload",
                  startedAt: clock.now(),
                  heartbeatAt: clock.now().addingTimeInterval(-300),
                  fractionCompleted: 0.2,
                  processedBytes: 10,
                  totalBytes: 50,
                  estimatedRemainingSeconds: nil,
                  errorCount: 1,
                  currentFolder: "/Users/privado/\(canaryToken)/\(canaryDocument)",
                  isStalled: true
                )
              )
            ),
            scheduledJobs: .loaded(.empty),
            capturedAt: clock.now()
          )
        ),
        .failure(RawExternalFailure(message: "Falha brain \(canaryToken) \(canaryDocument)")),
      ]
    )

    let spyDeliverer = SpyNotificationDeliverer()
    let store = UsageStore(
      collectors: [failingCollector, succeedingCollector],
      conversationCollector: nil,
      brainCollector: failingBrainCollector,
      notificationDeliverer: spyDeliverer,
      clock: clock,
      logger: logger,
      startPeriodicRefresh: false
    )
    await store.refresh()
    await store.refresh()

    XCTAssertFalse(spyDeliverer.deliveredAlerts.isEmpty)
    for alert in spyDeliverer.deliveredAlerts {
      assertNoCanary(in: alert.identifier)
      assertNoCanary(in: alert.incidentKey)
      assertNoCanary(in: alert.title)
      assertNoCanary(in: alert.body)
      XCTAssertFalse(alert.identifier.localizedStandardContains("flexograv"))
      XCTAssertFalse(alert.incidentKey.localizedStandardContains("flexograv"))
      XCTAssertFalse(alert.title.localizedStandardContains("flexograv"))
      XCTAssertFalse(alert.body.localizedStandardContains("flexograv"))
    }

    let canaryBackend = CanaryFailingNotificationBackend(
      failureMessage: "Notificação falhou \(canaryToken) \(canaryDocument)"
    )
    let adapter = UserNotificationCenterAdapter(backend: canaryBackend, logger: logger)
    await adapter.deliver(spyDeliverer.deliveredAlerts, refreshID: "canary-notify")

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

private nonisolated struct CanaryFailingNotificationBackend: UserNotificationBackend {
  struct CanaryBackendError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  let failureMessage: String

  func requestAlertOnlyAuthorization() async throws -> Bool {
    true
  }

  func enqueue(_: SystemNotificationPayload) async throws {
    throw CanaryBackendError(message: failureMessage)
  }
}
