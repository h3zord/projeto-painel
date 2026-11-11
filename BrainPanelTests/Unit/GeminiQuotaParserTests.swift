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
        "gemini-argon-weekly",
        "gemini-flash-session",
        "gemini-flash-weekly",
        "gemini-claude-gpt-session",
        "gemini-claude-gpt-weekly",
      ]
    )
    XCTAssertEqual(usage.weeklyLimit?.id, "gemini-argon-weekly")
    XCTAssertEqual(usage.weeklyLimit?.usedPercentage, 84)
    XCTAssertEqual(usage.sessionLimit?.id, "gemini-claude-gpt-session")
    XCTAssertEqual(usage.sessionLimit?.usedPercentage, 80)
    XCTAssertEqual(
      usage.sessionLimit?.resetsAt,
      fixedNow.addingTimeInterval(2 * 3_600 + 15 * 60)
    )
  }

  func testThrowsUnexpectedOutputWhenNoGroupsExist() {
    let emptyScreen = "Models & Quota\nNothing available"
    XCTAssertThrowsError(try GeminiQuotaParser.makeUsage(from: emptyScreen, now: fixedNow)) { error in
      let appError = error as? AppError
      XCTAssertEqual(appError?.code, .unexpectedOutputFormat)
    }
  }
}
