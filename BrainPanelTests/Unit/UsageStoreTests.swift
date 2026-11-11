import Foundation
import XCTest

@testable import BrainPanel

@MainActor
final class UsageStoreTests: XCTestCase {
  func testRefreshUpdatesProvidersConcurrentlyAndComputesLowestMenuBarLabel() async {
    let clock = TestClock()
    let logSink = InMemoryLogSink()
    let logger = StructuredLogger(clock: clock, sink: logSink)

    let claudeUsage = ProviderUsage(
      id: "claude",
      name: "Claude",
      plan: "Max",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      sessionState: .active,
      limits: [
        UsageLimit(
          id: "claude-session", name: "Sessão", detail: nil, window: .session, usedPercentage: 30,
          resetsAt: nil),
        UsageLimit(
          id: "claude-weekly", name: "Semanal", detail: nil, window: .weekly, usedPercentage: 55,
          resetsAt: nil),
      ]
    )
    let geminiUsage = ProviderUsage(
      id: "gemini",
      name: "Gemini",
      plan: "Google AI Pro",
      icon: .symbol("sparkle"),
      tint: .blue,
      sessionState: .active,
      limits: [
        UsageLimit(
          id: "gemini-argon-weekly", name: "Argon", detail: nil, window: .weekly, usedPercentage: 82,
          resetsAt: nil)
      ]
    )

    let claudeCollector = StubUsageCollector(providerID: "claude", results: [.success(claudeUsage)])
    let geminiCollector = StubUsageCollector(providerID: "gemini", results: [.success(geminiUsage)])
    let conversationCollector = StubConversationCollector(results: [.success(ActiveConversation.previewData)])

    let store = UsageStore(
      collectors: [claudeCollector, geminiCollector],
      conversationCollector: conversationCollector,
      clock: clock,
      logger: logger,
      startPeriodicRefresh: false
    )

    XCTAssertEqual(store.menuBarLabel, "—")
    await store.refresh()

    XCTAssertEqual(store.menuBarLabel, "18%")
    XCTAssertEqual(store.activeConversations.count, 2)
    XCTAssertEqual(store.lastUpdated, clock.now())
    XCTAssertTrue(logSink.lines.contains { $0.contains("\"refresh_id\":\"refresh-1\"") })
  }

  func testRefreshIfStaleRespectsSixtySecondCacheWindow() async {
    let clock = TestClock()
    let claudeUsage = ProviderUsage(
      id: "claude",
      name: "Claude",
      plan: "Pro",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      sessionState: .active,
      limits: [
        UsageLimit(
          id: "claude-session", name: "Sessão", detail: nil, window: .session, usedPercentage: 10,
          resetsAt: nil)
      ]
    )
    let claudeCollector = StubUsageCollector(providerID: "claude", results: [.success(claudeUsage)])
    let conversationCollector = StubConversationCollector(results: [.success([])])

    let store = UsageStore(
      collectors: [claudeCollector],
      conversationCollector: conversationCollector,
      clock: clock,
      cacheTTL: 60,
      startPeriodicRefresh: false
    )

    await store.refreshIfStale()
    XCTAssertEqual(claudeCollector.callCount, 1)
    XCTAssertEqual(conversationCollector.callCount, 1)

    clock.advance(by: 59)
    await store.refreshIfStale()
    XCTAssertEqual(claudeCollector.callCount, 1)
    XCTAssertEqual(conversationCollector.callCount, 1)

    clock.advance(by: 1)
    await store.refreshIfStale()
    XCTAssertEqual(claudeCollector.callCount, 2)
    XCTAssertEqual(conversationCollector.callCount, 2)
  }

  func testRefreshIfStaleRefreshesOnlyLocalSessionsWhenQuotasAreFreshAndSessionsFailed() async {
    let clock = TestClock()
    let logSink = InMemoryLogSink()
    let logger = StructuredLogger(clock: clock, sink: logSink)

    let claudeUsage = ProviderUsage(
      id: "claude",
      name: "Claude",
      plan: "Pro",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      sessionState: .active,
      limits: [
        UsageLimit(
          id: "claude-session", name: "Sessão", detail: nil, window: .session, usedPercentage: 10,
          resetsAt: nil)
      ]
    )
    let claudeCollector = StubUsageCollector(providerID: "claude", results: [.success(claudeUsage)])
    let conversationCollector = StubConversationCollector(
      results: [
        .failure(AppError.transcriptReadFailed()),
        .success(ActiveConversation.previewData),
      ]
    )

    let store = UsageStore(
      collectors: [claudeCollector],
      conversationCollector: conversationCollector,
      clock: clock,
      logger: logger,
      cacheTTL: 60,
      startPeriodicRefresh: false
    )

    await store.refreshIfStale()
    XCTAssertEqual(claudeCollector.callCount, 1)
    XCTAssertEqual(conversationCollector.callCount, 1)
    XCTAssertTrue(store.activeConversations.isEmpty)
    XCTAssertTrue(
      logSink.lines.contains {
        $0.contains("\"event\":\"sessions_refresh_failed\"")
          && $0.contains("\"error_code\":\"TRANSCRIPT_READ_FAILED\"")
      }
    )

    // Cotas continuam frescas (t = 10 s), mas lastConversationsUpdated permaneceu nil devido à falha:
    // refreshIfStale deve atualizar apenas as sessões locais (1x), sem rechamar o coletor de cotas.
    clock.advance(by: 10)
    await store.refreshIfStale()
    XCTAssertEqual(claudeCollector.callCount, 1)
    XCTAssertEqual(conversationCollector.callCount, 2)
    XCTAssertEqual(store.activeConversations.count, 2)
  }

  func testPreservesLastValidReadingAsStaleAndRecoversOnSubsequentSuccess() async {
    let clock = TestClock()
    let logSink = InMemoryLogSink()
    let logger = StructuredLogger(clock: clock, sink: logSink)

    let initialTimestamp = clock.now()
    let validClaude = ProviderUsage(
      id: "claude",
      name: "Claude",
      plan: "Max",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      sessionState: .active,
      limits: [
        UsageLimit(
          id: "claude-session", name: "Sessão", detail: nil, window: .session, usedPercentage: 25,
          resetsAt: nil)
      ]
    )
    let recoveredClaude = ProviderUsage(
      id: "claude",
      name: "Claude",
      plan: "Max",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      sessionState: .active,
      limits: [
        UsageLimit(
          id: "claude-session", name: "Sessão", detail: nil, window: .session, usedPercentage: 40,
          resetsAt: nil)
      ]
    )

    let claudeCollector = StubUsageCollector(
      providerID: "claude",
      results: [
        .success(validClaude),
        .failure(AppError.collectorTimedOut(provider: .claude)),
        .failure(AppError.executableNotFound(.claude)),
        .success(recoveredClaude),
      ]
    )
    let geminiCollector = StubUsageCollector(
      providerID: "gemini",
      results: [.failure(AppError.executableNotFound(.agy))]
    )

    let store = UsageStore(
      collectors: [claudeCollector, geminiCollector],
      conversationCollector: nil,
      clock: clock,
      logger: logger,
      startPeriodicRefresh: false
    )

    await store.refresh()
    XCTAssertEqual(store.providers[0].sessionState, .active)
    XCTAssertEqual(store.providers[0].lastUpdatedAt, initialTimestamp)
    XCTAssertEqual(store.menuBarLabel, "75%")
    XCTAssertEqual(
      store.providers[1].unavailableReason,
      AppError.executableNotFound(.agy).userMessage
    )

    clock.advance(by: 300)
    await store.refresh()
    XCTAssertEqual(
      store.providers[0].sessionState,
      .stale(
        reason: AppError.collectorTimedOut(provider: .claude).userMessage,
        lastUpdatedAt: initialTimestamp
      )
    )
    XCTAssertEqual(store.providers[0].sessionState.label, "Leitura defasada")
    XCTAssertEqual(store.providers[0].sessionLimit?.remainingPercentage, 75)
    XCTAssertEqual(store.menuBarLabel, "75%")
    XCTAssertTrue(logSink.lines.contains { $0.contains("collector_failed_preserved_cache") })

    // Segunda falha consecutiva preserva o carimbo original da última leitura válida e atualiza o motivo
    clock.advance(by: 300)
    await store.refresh()
    XCTAssertEqual(
      store.providers[0].sessionState,
      .stale(
        reason: AppError.executableNotFound(.claude).userMessage,
        lastUpdatedAt: initialTimestamp
      )
    )
    XCTAssertEqual(store.menuBarLabel, "75%")

    // Coleta futura bem-sucedida restaura .active com os novos limites e novo carimbo
    clock.advance(by: 300)
    let recoveryTimestamp = clock.now()
    await store.refresh()
    XCTAssertEqual(store.providers[0].sessionState, .active)
    XCTAssertNil(store.providers[0].staleReason)
    XCTAssertEqual(store.providers[0].lastUpdatedAt, recoveryTimestamp)
    XCTAssertEqual(store.providers[0].sessionLimit?.remainingPercentage, 60)
    XCTAssertEqual(store.menuBarLabel, "60%")
  }

  func testDeallocationCancelsPeriodicRefreshTask() async {
    let clock = TestClock()
    let sleepReached = expectation(description: "Loop periódico entrou em espera no Clock")
    sleepReached.assertForOverFulfill = false
    let sleepCancelled = expectation(description: "Tarefa periódica foi cancelada no deinit")
    sleepCancelled.assertForOverFulfill = false
    clock.onSleepStarted = {
      sleepReached.fulfill()
    }
    clock.onSleepCancelled = {
      sleepCancelled.fulfill()
    }

    let collector = StubUsageCollector(
      providerID: "claude",
      results: [.failure(AppError.executableNotFound(.claude))]
    )

    var store: UsageStore? = UsageStore(
      collectors: [collector],
      conversationCollector: nil,
      clock: clock,
      refreshInterval: .seconds(300),
      startPeriodicRefresh: true
    )
    XCTAssertNotNil(store)

    await fulfillment(of: [sleepReached], timeout: 3.0)
    XCTAssertEqual(clock.sleepCallCount, 1)
    XCTAssertEqual(clock.sleepCancelledCount, 0)

    store = nil
    await fulfillment(of: [sleepCancelled], timeout: 3.0)
    XCTAssertGreaterThanOrEqual(clock.sleepCancelledCount, 1)
  }

  func testRefreshUpdatesBrainSnapshotAndRetriesDegradedBrainSectionWhenQuotasAreFresh() async {
    let clock = TestClock()
    let logSink = InMemoryLogSink()
    let logger = StructuredLogger(clock: clock, sink: logSink)

    let claudeUsage = ProviderUsage(
      id: "claude",
      name: "Claude",
      plan: "Pro",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      sessionState: .active,
      limits: [
        UsageLimit(
          id: "claude-session", name: "Sessão", detail: nil, window: .session, usedPercentage: 20,
          resetsAt: nil)
      ]
    )
    let claudeCollector = StubUsageCollector(providerID: "claude", results: [.success(claudeUsage)])

    let degradedSnapshot = BrainSnapshot(
      waiting: .loaded(
        WaitingState(
          pendingPrompts: [
            PendingPrompt(
              sessionKey: "painel-lead",
              askedAt: clock.now().addingTimeInterval(-120),
              text: "Escolha A",
              isExplicit: true,
              hasButton: true
            )
          ],
          stuckMail: [],
          closedMail: []
        )
      ),
      ciQueue: .loaded(.empty),
      healthAndBackup: .failed(AppError.brainStateReadFailed(section: .healthAndBackup)),
      scheduledJobs: .loaded(.empty),
      capturedAt: clock.now()
    )
    let healthySnapshot = BrainSnapshot(
      waiting: degradedSnapshot.waiting,
      ciQueue: .loaded(.empty),
      healthAndBackup: .loaded(.empty),
      scheduledJobs: .loaded(.empty),
      capturedAt: clock.now()
    )

    let brainCollector = StubBrainStateCollector(
      results: [.success(degradedSnapshot), .success(healthySnapshot)]
    )

    let store = UsageStore(
      collectors: [claudeCollector],
      conversationCollector: nil,
      brainCollector: brainCollector,
      clock: clock,
      logger: logger,
      cacheTTL: 60,
      startPeriodicRefresh: false
    )

    await store.refreshIfStale()
    XCTAssertEqual(claudeCollector.callCount, 1)
    XCTAssertEqual(brainCollector.callCount, 1)
    XCTAssertEqual(store.brainSnapshot.waitingOnOwnerCount, 1)
    XCTAssertEqual(store.brainSnapshot.degradedSections, [.healthAndBackup])
    XCTAssertTrue(logSink.lines.contains { $0.contains("\"event\":\"brain_state_partially_degraded\"") })

    // Cotas frescas (t = 15 s), mas brainSnapshot teve seção degradada (lastBrainUpdated == nil):
    // refreshIfStale deve rechamar apenas o estado local (brainCollector), sem rechamar cotas.
    clock.advance(by: 15)
    await store.refreshIfStale()
    XCTAssertEqual(claudeCollector.callCount, 1)
    XCTAssertEqual(brainCollector.callCount, 2)
    XCTAssertTrue(store.brainSnapshot.degradedSections.isEmpty)
    XCTAssertTrue(logSink.lines.contains { $0.contains("\"event\":\"brain_state_refreshed\"") })

    // Agora tudo está fresco dentro da janela de 60 s.
    clock.advance(by: 20)
    await store.refreshIfStale()
    XCTAssertEqual(brainCollector.callCount, 2)
  }

  func testSmartMenuBarLabelAccessibilityAndFooterSummariesAcrossAllStates() async {
    let clock = TestClock()
    let claudeUsage = ProviderUsage(
      id: "claude",
      name: "Claude",
      plan: "Max",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      sessionState: .active,
      limits: [
        UsageLimit(
          id: "claude-session",
          name: "Sessão",
          detail: nil,
          window: .session,
          usedPercentage: 58,
          resetsAt: nil
        )
      ]
    )

    let waitingOnlySnapshot = BrainSnapshot(
      waiting: .loaded(
        WaitingState(
          pendingPrompts: [
            PendingPrompt(
              sessionKey: "painel-lead",
              askedAt: clock.now().addingTimeInterval(-60),
              text: "Pergunta 1",
              isExplicit: true,
              hasButton: true
            ),
            PendingPrompt(
              sessionKey: "caixa-lead",
              askedAt: clock.now().addingTimeInterval(-30),
              text: "Pergunta 2",
              isExplicit: true,
              hasButton: false
            ),
          ],
          stuckMail: [],
          closedMail: []
        )
      ),
      ciQueue: .loaded(.empty),
      healthAndBackup: .loaded(.empty),
      scheduledJobs: .loaded(.empty),
      capturedAt: clock.now()
    )

    let criticalAndWaitingSnapshot = BrainSnapshot(
      waiting: waitingOnlySnapshot.waiting,
      ciQueue: .loaded(.empty),
      healthAndBackup: .loaded(
        HealthAndBackupState(
          doctorFailures: [
            DoctorFinding(key: "FAIL 14", severity: .fail, message: "backup atrasado")
          ],
          doctorWarnings: [],
          doctorCheckedAt: clock.now(),
          testSuite: nil,
          syncStatus: nil,
          backupStatus: nil,
          liveBackupProgress: nil
        )
      ),
      scheduledJobs: .loaded(.empty),
      capturedAt: clock.now()
    )

    let claudeCollector = StubUsageCollector(
      providerID: "claude",
      results: [
        .failure(AppError.executableNotFound(.claude)),
        .success(claudeUsage),
        .success(claudeUsage),
      ]
    )
    let brainCollector = StubBrainStateCollector(
      results: [
        .success(waitingOnlySnapshot),
        .success(waitingOnlySnapshot),
        .success(criticalAndWaitingSnapshot),
      ]
    )

    let store = UsageStore(
      collectors: [claudeCollector],
      conversationCollector: nil,
      brainCollector: brainCollector,
      clock: clock,
      startPeriodicRefresh: false
    )

    // Estado inicial antes da primeira leitura
    XCTAssertEqual(store.menuBarLabel, "—")
    XCTAssertEqual(store.menuBarAccessibilityLabel, "Brain Panel: cota indisponível")
    XCTAssertEqual(store.footerStatusSummary(now: clock.now()), "Aguardando leitura")

    // 1ª coleta: sem cota utilizável, mas com 2 pendências no Brain -> "— · 2"
    await store.refresh()
    XCTAssertEqual(store.menuBarLabel, "— · 2")
    XCTAssertEqual(
      store.menuBarAccessibilityLabel,
      "Brain Panel: cota indisponível, 2 itens esperando você"
    )
    XCTAssertEqual(store.footerStatusSummary(now: clock.now()), "Atualizado há instantes")

    // 2ª coleta: cota de 42% disponível + 2 pendências no Brain -> "42% · 2"
    clock.advance(by: 120)
    await store.refresh()
    XCTAssertEqual(store.menuBarLabel, "42% · 2")
    XCTAssertEqual(
      store.menuBarAccessibilityLabel,
      "Brain Panel: menor cota disponível 42%, 2 itens esperando você"
    )

    // 3ª coleta: falha crítica tem prioridade maior sobre contagem de pendências no rótulo curto -> "42% · !"
    clock.advance(by: 180)
    await store.refresh()
    XCTAssertEqual(store.menuBarLabel, "42% · !")
    XCTAssertEqual(
      store.menuBarAccessibilityLabel,
      "Brain Panel: menor cota disponível 42%, falha crítica no Brain, 2 itens esperando você"
    )
    clock.advance(by: 300)
    XCTAssertEqual(store.footerStatusSummary(now: clock.now()), "Atualizado há 5m")
  }

  func testConversationCollectorFailurePreservesPreviousListAndExposesDiagnosticUntilRecovered()
    async
  {
    let clock = TestClock()
    let conversationCollector = StubConversationCollector(
      results: [
        .success(ActiveConversation.previewData),
        .failure(AppError.transcriptReadFailed()),
        .success([]),
      ]
    )

    let store = UsageStore(
      collectors: [],
      conversationCollector: conversationCollector,
      clock: clock,
      startPeriodicRefresh: false
    )

    XCTAssertNil(store.lastConversationsError)
    await store.refresh()
    XCTAssertEqual(store.activeConversations.count, 2)
    XCTAssertNil(store.lastConversationsError)

    clock.advance(by: 60)
    await store.refresh()
    XCTAssertEqual(store.activeConversations.count, 2)
    XCTAssertEqual(store.lastConversationsError?.code, .transcriptReadFailed)

    clock.advance(by: 60)
    await store.refresh()
    XCTAssertTrue(store.activeConversations.isEmpty)
    XCTAssertNil(store.lastConversationsError)
  }

  func testMenuBarPresentationSingularItemAndSynchronizingFooter() {
    let now = Date(timeIntervalSince1970: 1_762_819_200)
    XCTAssertEqual(
      MenuBarPresentation.label(
        lowestRemainingPercentage: nil,
        waitingOnOwnerCount: 0,
        hasCriticalFailure: true
      ),
      "— · !"
    )
    XCTAssertEqual(
      MenuBarPresentation.accessibilityLabel(
        lowestRemainingPercentage: 75,
        waitingOnOwnerCount: 1,
        hasCriticalFailure: false
      ),
      "Brain Panel: menor cota disponível 75%, 1 item esperando você"
    )
    XCTAssertEqual(
      MenuBarPresentation.footerStatusSummary(
        lastRefreshAt: nil,
        isRefreshing: true,
        now: now
      ),
      "Sincronizando…"
    )
  }

  func testRefreshLocalStateRunsConversationAndBrainCollectorsInParallel() async {
    let clock = TestClock()
    let gate = ParallelCollectorRendezvousGate()

    let conversationCollector = GateConversationCollector(gate: gate)
    let brainCollector = GateBrainCollector(gate: gate)

    let store = UsageStore(
      collectors: [],
      conversationCollector: conversationCollector,
      brainCollector: brainCollector,
      clock: clock,
      startPeriodicRefresh: false
    )

    await store.refreshLocalState()
    let maxInFlight = await gate.maxConcurrentParticipants
    XCTAssertEqual(maxInFlight, 2)
  }

  func testRefreshAndRefreshLocalStateDispatchDiscreteAlertsOnceAndIsolateNonLiveRuntimeModes()
    async throws
  {
    let clock = TestClock()
    let spyDeliverer = SpyNotificationDeliverer()

    let criticalClaude = ProviderUsage(
      id: "claude",
      name: "Claude",
      plan: "Max",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      sessionState: .active,
      limits: [
        UsageLimit(
          id: "claude-session",
          name: "Sessão de 5 horas",
          detail: nil,
          window: .session,
          usedPercentage: 88,
          resetsAt: nil
        )
      ]
    )
    let waitingSnapshot = BrainSnapshot(
      waiting: .loaded(
        WaitingState(
          pendingPrompts: [
            PendingPrompt(
              sessionKey: "painel-lead",
              askedAt: clock.now().addingTimeInterval(-60),
              text: "Pergunta",
              isExplicit: true,
              hasButton: true
            )
          ],
          stuckMail: [],
          closedMail: []
        )
      ),
      ciQueue: .loaded(.empty),
      healthAndBackup: .loaded(.empty),
      scheduledJobs: .loaded(.empty),
      capturedAt: clock.now()
    )
    let doctorFailAndResolvedWaitingSnapshot = BrainSnapshot(
      waiting: .loaded(.empty),
      ciQueue: .loaded(.empty),
      healthAndBackup: .loaded(
        HealthAndBackupState(
          doctorFailures: [
            DoctorFinding(key: "FAIL 7", severity: .fail, message: "erro doctor")
          ],
          doctorWarnings: [],
          doctorCheckedAt: clock.now(),
          testSuite: nil,
          syncStatus: nil,
          backupStatus: nil,
          liveBackupProgress: nil
        )
      ),
      scheduledJobs: .loaded(.empty),
      capturedAt: clock.now()
    )

    let claudeCollector = StubUsageCollector(
      providerID: "claude",
      results: [.success(criticalClaude)]
    )
    let brainCollector = StubBrainStateCollector(
      results: [
        .success(waitingSnapshot),
        .success(doctorFailAndResolvedWaitingSnapshot),
        .success(waitingSnapshot),
      ]
    )

    let store = UsageStore(
      collectors: [claudeCollector],
      conversationCollector: nil,
      brainCollector: brainCollector,
      notificationDeliverer: spyDeliverer,
      notificationCooldownSeconds: 3_600,
      clock: clock,
      startPeriodicRefresh: false
    )

    // 1. refresh() completo entrega 1 único lote combinando cota + Brain (sem duplicar no passo local interno)
    await store.refresh()
    XCTAssertEqual(spyDeliverer.callCount, 1)
    XCTAssertEqual(
      spyDeliverer.batches.first?.alerts.map(\.incidentKey),
      ["quota:claude:claude-session", "waiting:prompt:painel-lead"]
    )

    // 2. refreshLocalState() após 30s: cota continua em cooldown; waiting foi resolvido; doctor FAIL novo dispara
    clock.advance(by: 30)
    await store.refreshLocalState()
    XCTAssertEqual(spyDeliverer.callCount, 2)
    XCTAssertEqual(
      spyDeliverer.batches.last?.alerts.map(\.incidentKey),
      ["health:doctor_failure"]
    )

    // 3. refreshLocalState() após mais 30s: waiting voltou após ter sido resolvido -> rearme imediato!
    clock.advance(by: 30)
    await store.refreshLocalState()
    XCTAssertEqual(spyDeliverer.callCount, 3)
    XCTAssertEqual(
      spyDeliverer.batches.last?.alerts.map(\.incidentKey),
      ["waiting:prompt:painel-lead"]
    )

    // 4. Isolamento de modos fora de .live em UsageStore.makeForRuntime / shouldUseLiveNotifications
    let homeURL = URL(filePath: "/Users/teste", directoryHint: .isDirectory)
    let supportURL = URL(
      filePath: "/Users/teste/Library/Application Support",
      directoryHint: .isDirectory
    )
    let tempURL = FileManager.default.temporaryDirectory.appending(
      path: "brain-panel-store-mode-test-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let liveEnabled = try AppConfig.parse(
      environment: ["BRAIN_PANEL_MODE": "live"],
      defaultHomeDirectory: homeURL,
      defaultAppSupportRoot: supportURL,
      defaultTemporaryRoot: tempURL,
      bundleIdentifier: "com.h3zord.BrainPanel"
    )
    let liveDisabled = try AppConfig.parse(
      environment: [
        "BRAIN_PANEL_MODE": "live",
        "BRAIN_PANEL_NOTIFICATIONS_ENABLED": "false",
      ],
      defaultHomeDirectory: homeURL,
      defaultAppSupportRoot: supportURL,
      defaultTemporaryRoot: tempURL,
      bundleIdentifier: "com.h3zord.BrainPanel"
    )
    XCTAssertTrue(UsageStore.shouldUseLiveNotifications(for: liveEnabled))
    XCTAssertFalse(UsageStore.shouldUseLiveNotifications(for: liveDisabled))

    for nonLiveMode in ["isolated", "self_check", "testing"] {
      let forcedTrueNonLive = try AppConfig.parse(
        environment: [
          "BRAIN_PANEL_MODE": nonLiveMode,
          "BRAIN_PANEL_NOTIFICATIONS_ENABLED": "true",
        ],
        defaultHomeDirectory: homeURL,
        defaultAppSupportRoot: supportURL,
        defaultTemporaryRoot: tempURL,
        bundleIdentifier: "com.h3zord.BrainPanel"
      )
      XCTAssertFalse(UsageStore.shouldUseLiveNotifications(for: forcedTrueNonLive))
      let runtimeStore = UsageStore.makeForRuntime(config: forcedTrueNonLive, clock: clock)
      runtimeStore.stopPeriodicRefresh()
      XCTAssertFalse(runtimeStore.hasNotificationDeliverer)
    }
  }
}

private actor ParallelCollectorRendezvousGate {
  private var arrivedCount = 0
  private(set) var maxConcurrentParticipants = 0
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func arriveAndWaitForPartner() async {
    arrivedCount += 1
    maxConcurrentParticipants = max(maxConcurrentParticipants, arrivedCount)
    if arrivedCount >= 2 {
      let pending = continuations
      continuations.removeAll()
      for continuation in pending {
        continuation.resume()
      }
      return
    }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }
}

private nonisolated final class GateConversationCollector: ConversationCollecting {
  private let gate: ParallelCollectorRendezvousGate

  init(gate: ParallelCollectorRendezvousGate) {
    self.gate = gate
  }

  func fetchActiveConversations() async throws -> [ActiveConversation] {
    await gate.arriveAndWaitForPartner()
    return []
  }
}

private nonisolated final class GateBrainCollector: BrainStateCollecting {
  private let gate: ParallelCollectorRendezvousGate

  init(gate: ParallelCollectorRendezvousGate) {
    self.gate = gate
  }

  func fetchBrainState() async throws -> BrainSnapshot {
    await gate.arriveAndWaitForPartner()
    return .empty
  }
}
