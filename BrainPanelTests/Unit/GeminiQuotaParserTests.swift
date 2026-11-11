import Foundation
import XCTest

@testable import BrainPanel

final class GeminiQuotaParserTests: XCTestCase {
  private let fixedNow = Date(timeIntervalSince1970: 1_762_800_000)

  func testParsesAllModelGroupsAndOrdersSessionBeforeWeekly() throws {
    let screen = """
      Google AI Pro
      Models & Quota

      CLAUDE AND GPT MODELS
      Weekly Limit
      59%
      Refreshes in 4d 3h
      5-Hour Limit
      20%  Refreshes in 2h 15m

      GEMINI 4 ARGON
      Weekly Limit
      16%
      Refreshes in 46h 30m

      GEMINI MODELS
      Five Hour Limit
      100%
      Weekly Limit
      99% Refreshes in 51h

      Within each group models share quota.
      """

    let usage = try GeminiQuotaParser.makeUsage(from: screen, now: fixedNow)
    XCTAssertEqual(usage.id, "gemini")
    XCTAssertEqual(usage.plan, "Google AI Pro")
    XCTAssertEqual(
      usage.limits.map(\.id),
      [
        "gemini-claude-and-gpt-models-session",
        "gemini-claude-and-gpt-models-weekly",
        "gemini-4-argon-weekly",
        "gemini-models-session",
        "gemini-models-weekly",
      ]
    )
    XCTAssertEqual(usage.weeklyLimit?.id, "gemini-4-argon-weekly")
    XCTAssertEqual(usage.weeklyLimit?.usedPercentage, 84)
    XCTAssertEqual(usage.sessionLimit?.id, "gemini-claude-and-gpt-models-session")
    XCTAssertEqual(usage.sessionLimit?.usedPercentage, 80)
    XCTAssertEqual(
      usage.sessionLimit?.resetsAt,
      fixedNow.addingTimeInterval(2 * 3_600 + 15 * 60)
    )
  }

  func testExtractsDynamicGroupsWithPunctuationWithoutDroppingUnknownModels() throws {
    let screen = """
      Google AI Ultra
      Models & Quota

      GEMINI 4 CARBON
      Weekly Limit
      12% Refreshes in 2d 5h
      5-Hour Limit
      65% Refreshes in 3h 10m

      GEMINI 2.5 PRO
      Five Hour Limit
      90% Refreshes in 4h
      Weekly Limit
      40% Refreshes in 6d

      CLAUDE & GPT-4.5 / SONNET
      Weekly Limit
      5% Refreshes in 1d 2h

      GEMINI 2.5 PRO (PREVIEW)
      Weekly Limit
      70% Refreshes in 3d

      OPENAI: (GPT)
      Weekly Limit
      80% Refreshes in 5d

      Within each group models share quota.
      Context Limit
      98% context left
      """

    let usage = try GeminiQuotaParser.makeUsage(from: screen, now: fixedNow)
    XCTAssertEqual(usage.plan, "Google AI Ultra")
    XCTAssertEqual(
      usage.limits.map(\.id),
      [
        "gemini-4-carbon-session",
        "gemini-4-carbon-weekly",
        "gemini-2-5-pro-session",
        "gemini-2-5-pro-weekly",
        "gemini-claude-gpt-4-5-sonnet-weekly",
        "gemini-2-5-pro-preview-weekly",
        "gemini-openai-gpt-weekly",
      ]
    )
    XCTAssertEqual(
      usage.limits.map(\.name),
      [
        "Gemini 4 Carbon",
        "Gemini 4 Carbon",
        "Gemini 2.5 Pro",
        "Gemini 2.5 Pro",
        "Claude & GPT-4.5 / Sonnet",
        "Gemini 2.5 Pro (Preview)",
        "Openai: (GPT)",
      ]
    )
    // O texto "Context Limit / 98%" abaixo de "Within each group" não pode sobrescrever o último grupo (20% usado)
    XCTAssertEqual(usage.limits.last?.usedPercentage, 20)
    // A janela semanal mais consumida é Claude & GPT-4.5 / Sonnet (95% usado, 5% restante)
    XCTAssertEqual(usage.weeklyLimit?.id, "gemini-claude-gpt-4-5-sonnet-weekly")
    XCTAssertEqual(usage.weeklyLimit?.usedPercentage, 95)
    XCTAssertEqual(usage.sessionLimit?.id, "gemini-4-carbon-session")
    XCTAssertEqual(usage.sessionLimit?.usedPercentage, 35)
  }

  func testThrowsUnexpectedOutputWhenNoGroupsExist() {
    let emptyScreen = "Models & Quota\nNothing available"
    XCTAssertThrowsError(try GeminiQuotaParser.makeUsage(from: emptyScreen, now: fixedNow)) { error in
      let appError = error as? AppError
      XCTAssertEqual(appError?.code, .unexpectedOutputFormat)
    }
  }
}
