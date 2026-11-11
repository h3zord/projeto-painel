import Foundation
import XCTest

@testable import BrainPanel

final class ProviderUsageTests: XCTestCase {
  func testPlaceholdersContainOnlyClaudeAndGemini() {
    let ids = ProviderUsage.placeholders.map(\.id)
    XCTAssertEqual(ids, ["claude", "gemini"])
    XCTAssertTrue(ProviderUsage.placeholders.allSatisfy { $0.sessionState == .unavailable("Carregando") })
  }

  func testUsageLimitClampsPercentageBounds() {
    let negative = UsageLimit(
      id: "low",
      name: "Sessão",
      detail: nil,
      window: .session,
      usedPercentage: -15,
      resetsAt: nil
    )
    XCTAssertEqual(negative.usedPercentage, 0)
    XCTAssertEqual(negative.remainingPercentage, 100)
    XCTAssertEqual(negative.fraction, 0.0, accuracy: 0.0001)

    let over = UsageLimit(
      id: "high",
      name: "Sessão",
      detail: nil,
      window: .session,
      usedPercentage: 145,
      resetsAt: nil
    )
    XCTAssertEqual(over.usedPercentage, 100)
    XCTAssertEqual(over.remainingPercentage, 0)
    XCTAssertEqual(over.fraction, 1.0, accuracy: 0.0001)
  }

  func testSessionLimitPicksMostConsumedFiveHourWindow() {
    let provider = ProviderUsage(
      id: "gemini",
      name: "Gemini",
      plan: "Google AI Pro",
      icon: .symbol("sparkle"),
      tint: .blue,
      sessionState: .active,
      limits: [
        UsageLimit(id: "s1", name: "Flash", detail: nil, window: .session, usedPercentage: 20, resetsAt: nil),
        UsageLimit(
          id: "s2", name: "Claude e GPT", detail: nil, window: .session, usedPercentage: 75, resetsAt: nil),
        UsageLimit(id: "w1", name: "Argon", detail: nil, window: .weekly, usedPercentage: 90, resetsAt: nil),
      ]
    )

    XCTAssertEqual(provider.sessionLimit?.id, "s2")
    XCTAssertEqual(provider.sessionLimit?.remainingPercentage, 25)
  }

  func testWeeklyLimitPicksMostConsumedWeeklyWindowUniformlyAcrossGroups() {
    let provider = ProviderUsage(
      id: "gemini",
      name: "Gemini",
      plan: "Google AI Pro",
      icon: .symbol("sparkle"),
      tint: .blue,
      sessionState: .active,
      limits: [
        UsageLimit(
          id: "gemini-argon-weekly",
          name: "Gemini 4 Argon",
          detail: "Semanal",
          window: .weekly,
          usedPercentage: 30,
          resetsAt: nil
        ),
        UsageLimit(
          id: "gemini-4-carbon-weekly",
          name: "Gemini 4 Carbon",
          detail: "Semanal",
          window: .weekly,
          usedPercentage: 85,
          resetsAt: nil
        ),
      ]
    )

    XCTAssertEqual(provider.weeklyLimit?.id, "gemini-4-carbon-weekly")
    XCTAssertEqual(provider.weeklyLimit?.usedPercentage, 85)
    XCTAssertEqual(provider.weeklyLimit?.remainingPercentage, 15)
  }

  func testUnavailableResetsLimitsAndExposesReason() {
    let now = Date(timeIntervalSince1970: 1_762_819_200)
    guard let active = ProviderUsage.makePreviewData(now: now).first else {
      XCTFail("Preview data ausente")
      return
    }
    XCTAssertNil(active.unavailableReason)
    XCTAssertNil(active.staleReason)
    XCTAssertTrue(active.sessionState.hasUsableQuota)
    XCTAssertFalse(active.sessionState.isStale)
    XCTAssertEqual(active.sessionState.label, "Sessão ativa")

    let degraded = active.unavailable("CLI ausente")
    XCTAssertEqual(degraded.unavailableReason, "CLI ausente")
    XCTAssertFalse(degraded.sessionState.hasUsableQuota)
    XCTAssertEqual(degraded.sessionState.label, "Indisponível")
    XCTAssertTrue(degraded.limits.isEmpty)
  }

  func testStalePreservesLimitsAndOriginalTimestampAndFormatsAgeDeterministically() {
    let capturedAt = Date(timeIntervalSince1970: 1_762_819_200)
    guard let active = ProviderUsage.makePreviewData(now: capturedAt).first else {
      XCTFail("Preview data ausente")
      return
    }

    let firstFailureAt = capturedAt.addingTimeInterval(300)
    let firstStale = active.stale(reason: "Tempo esgotado", fallbackDate: firstFailureAt)
    XCTAssertTrue(firstStale.sessionState.hasUsableQuota)
    XCTAssertTrue(firstStale.sessionState.isStale)
    XCTAssertEqual(firstStale.sessionState.label, "Leitura defasada")
    XCTAssertEqual(firstStale.staleReason, "Tempo esgotado")
    XCTAssertEqual(firstStale.staleLastUpdatedAt, capturedAt)
    XCTAssertEqual(firstStale.limits, active.limits)

    let secondFailureAt = capturedAt.addingTimeInterval(900)
    let secondStale = firstStale.stale(reason: "CLI indisponível", fallbackDate: secondFailureAt)
    XCTAssertEqual(secondStale.staleReason, "CLI indisponível")
    XCTAssertEqual(secondStale.staleLastUpdatedAt, capturedAt)

    XCTAssertEqual(
      ProviderUsage.staleAgeSummary(since: capturedAt, now: capturedAt.addingTimeInterval(30)),
      "Última leitura válida há instantes"
    )
    XCTAssertEqual(
      ProviderUsage.staleAgeSummary(since: capturedAt, now: capturedAt.addingTimeInterval(5 * 60)),
      "Última leitura válida há 5m"
    )
    XCTAssertEqual(
      ProviderUsage.staleAgeSummary(
        since: capturedAt,
        now: capturedAt.addingTimeInterval(2 * 3_600 + 15 * 60)
      ),
      "Última leitura válida há 2h 15m"
    )
    XCTAssertEqual(
      ProviderUsage.staleAgeSummary(
        since: capturedAt,
        now: capturedAt.addingTimeInterval(27 * 3_600)
      ),
      "Última leitura válida há 1d 3h"
    )
  }
}
