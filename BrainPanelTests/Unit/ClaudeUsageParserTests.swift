import Foundation
import XCTest

@testable import BrainPanel

final class ClaudeUsageParserTests: XCTestCase {
  private let fixedNow = Date(timeIntervalSince1970: 1_762_800_000)  // 2025-11-10T18:40:00Z

  func testParsesSessionAndAllModelsWeeklyUsage() throws {
    let screen = """
      Claude Max
      Current session ████░░░░░░ 38% used Resets 11:30pm (UTC)
      Current week (all models) ██░░░░░░░░ 19% used Resets Nov 14 at 3am (UTC)
      Current week (Sonnet only) █░░░░░░░░░ 5% used Resets Nov 14 at 3am (UTC)
      """

    let usage = try ClaudeUsageParser.makeUsage(from: screen, now: fixedNow)
    XCTAssertEqual(usage.id, "claude")
    XCTAssertEqual(usage.plan, "Max")
    XCTAssertEqual(usage.limits.count, 2)
    XCTAssertEqual(usage.limits[0].id, "claude-session")
    XCTAssertEqual(usage.limits[0].usedPercentage, 38)
    XCTAssertEqual(usage.limits[0].remainingPercentage, 62)
    XCTAssertNotNil(usage.limits[0].resetsAt)
    XCTAssertEqual(usage.limits[1].id, "claude-weekly")
    XCTAssertEqual(usage.limits[1].usedPercentage, 19)
    XCTAssertNotNil(usage.limits[1].resetsAt)
  }

  func testRedrawnScreenUsesLatestValues() throws {
    let screen = """
      Claude Pro
      Current session ██ 10% used Resets 9pm (UTC)
      Current week (all models) ██ 12% used Resets Nov 14, 3:00pm (UTC)
      Current session ██████ 64% used Resets 9pm (UTC)
      Current week (all models) ████ 41% used Resets Nov 14, 3:00pm (UTC)
      """

    let usage = try ClaudeUsageParser.makeUsage(from: screen, now: fixedNow)
    XCTAssertEqual(usage.plan, "Pro")
    XCTAssertEqual(usage.sessionLimit?.usedPercentage, 64)
    XCTAssertEqual(usage.weeklyLimit?.usedPercentage, 41)
  }

  func testResetDateRollsToNextDayAndNextYearWhenNeeded() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

    // 18:40 UTC -> "2pm" já passou hoje, então deve cair amanhã às 14:00 UTC.
    let tomorrowReset = ClaudeUsageParser.resetDate(text: "2pm", timeZone: "UTC", now: fixedNow)
    XCTAssertEqual(tomorrowReset, fixedNow.addingTimeInterval(19 * 3_600 + 20 * 60))

    // Em dezembro, um reset em "Jan 2 at 12am" pertence ao ano seguinte.
    let decComponents = DateComponents(year: 2026, month: 12, day: 30, hour: 10, minute: 0)
    let decDate = calendar.date(from: decComponents) ?? fixedNow
    let janReset = ClaudeUsageParser.resetDate(text: "Jan 2 at 12am", timeZone: "UTC", now: decDate)
    let expectedJan = calendar.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 0, minute: 0))
    XCTAssertEqual(janReset, expectedJan)
  }

  func testThrowsUnexpectedOutputFormatWhenSessionMissing() {
    let invalidScreen = "Tela vazia sem barras de cota"
    XCTAssertThrowsError(try ClaudeUsageParser.makeUsage(from: invalidScreen, now: fixedNow)) { error in
      let appError = error as? AppError
      XCTAssertEqual(appError?.code, .unexpectedOutputFormat)
    }
  }
}
