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

  func testPreservesLastValidReadingWhenSubsequentRefreshFails() async {
    let clock = TestClock()
    let logSink = InMemoryLogSink()
    let logger = StructuredLogger(clock: clock, sink: logSink)

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

    let claudeCollector = StubUsageCollector(
      providerID: "claude",
      results: [
        .success(validClaude),
        .failure(AppError.collectorTimedOut(provider: .claude)),
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
    XCTAssertEqual(
      store.providers[1].unavailableReason,
      AppError.executableNotFound(.agy).userMessage
    )

    await store.refresh()
    XCTAssertEqual(store.providers[0].sessionState, .active)
    XCTAssertEqual(store.providers[0].sessionLimit?.remainingPercentage, 75)
    XCTAssertTrue(logSink.lines.contains { $0.contains("collector_failed_preserved_cache") })
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
}
