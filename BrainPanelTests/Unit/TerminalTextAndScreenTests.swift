import Darwin
import Foundation
import XCTest

@testable import BrainPanel

final class TerminalTextAndScreenTests: XCTestCase {
  func testTerminalTextReplacesCursorMovesAndStripsEscapeCodes() {
    let raw = "\u{1b}[32mCurrent\u{1b}[3Csession\u{1b}[25G42% used\u{1b}[0m\r\n"
    let cleaned = TerminalText.clean(Data(raw.utf8))
    XCTAssertEqual(cleaned, "Current   session 42% used\n")
  }

  func testTerminalTextStripsReverseIndexEscapeM() {
    let raw = "Signing in...\r\u{1b}M\u{1b}[2KAntigravity CLI 1.5.5\r\n"
    let cleaned = TerminalText.clean(Data(raw.utf8))
    XCTAssertEqual(cleaned, "Signing in...Antigravity CLI 1.5.5\n")
  }

  func testTerminalScreenHandlesReverseIndexEscapeMWithoutUnderflow() {
    let raw =
      "\u{1b}MWelcome to the Antigravity CLI. You are currently not signed in.\r\n"
      + "Signing in...\r\u{1b}[2K\u{1b}M\r\u{1b}[2KAntigravity CLI 1.5.5 (Google AI Ultra)\r\n"
      + "> \r\n"
      + "Auto mode: edits & safe commands auto-approved (shift+tab to cycle)"
    let screen = TerminalScreen.render(Data(raw.utf8), columns: 80, rows: 6)
    let nonEmptyLines = screen.split(separator: "\n").map(String.init)
    XCTAssertEqual(
      nonEmptyLines,
      [
        "Antigravity CLI 1.5.5 (Google AI Ultra)",
        ">",
        "Auto mode: edits & safe commands auto-approved (shift+tab to cycle)",
      ]
    )
  }

  func testTerminalScreenHandlesRedrawInPlaceAndAlternateBuffer() {
    let raw =
      "\u{1b}[?1049h"
      + "Linha velha que será apagada\r\u{1b}[2KModels & Quota\r\n"
      + "GEMINI 4 ARGON\r\n"
      + "Weekly Limit\r\n"
      + "10%\u{1b}[1A\r\u{1b}[2KWeekly Limit\r\n"
      + "\u{1b}[2K75% Refreshes in 12h"
    let screen = TerminalScreen.render(Data(raw.utf8), columns: 60, rows: 8)
    let nonEmptyLines = screen.split(separator: "\n").map(String.init)
    XCTAssertEqual(
      nonEmptyLines,
      [
        "Models & Quota",
        "GEMINI 4 ARGON",
        "Weekly Limit",
        "75% Refreshes in 12h",
      ]
    )
  }

  func testWriteAllRetriesPartialWritesAndEINTR() throws {
    let expected = Array("comando /quota completo com UTF-8 çãõ\r\n".utf8)
    var captured: [UInt8] = []
    var callNumber = 0

    try PseudoTerminalSession.writeAll(expected) { pointer, remaining in
      callNumber += 1
      if callNumber == 2 {
        return (-1, EINTR)
      }
      if callNumber == 4 {
        return (-1, EAGAIN)
      }
      let chunkCount = min(3, remaining)
      let bytes = UnsafeRawBufferPointer(start: pointer, count: chunkCount)
      captured.append(contentsOf: bytes)
      return (chunkCount, 0)
    }

    XCTAssertEqual(captured, expected)
    XCTAssertGreaterThan(callNumber, 5)
  }

  func testWriteAllThrowsTerminalWriteFailedOnHardDescriptorError() {
    let payload = Array("/usage\r".utf8)
    XCTAssertThrowsError(
      try PseudoTerminalSession.writeAll(payload) { _, _ in
        (-1, EPIPE)
      }
    ) { error in
      let appError = error as? AppError
      XCTAssertEqual(appError?.code, .terminalWriteFailed)
    }
  }
}
