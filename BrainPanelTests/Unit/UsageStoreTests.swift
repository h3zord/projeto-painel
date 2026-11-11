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
}
