import Foundation
import XCTest

@testable import BrainPanel

final class ActiveConversationDomainTests: XCTestCase {
  func testStatusBoundariesAtSoftAndHardLimits() {
    let belowSoft = makeConversation(tokens: 299_999)
    XCTAssertEqual(belowSoft.statusLevel, .normal)
    XCTAssertEqual(belowSoft.statusDetail, "1 até 300 mil")

    let exactSoft = makeConversation(tokens: 300_000)
    XCTAssertEqual(exactSoft.statusLevel, .softWarning)
    XCTAssertEqual(exactSoft.statusDetail, "Acima de 300 mil (compactar na troca)")

    let belowHard = makeConversation(tokens: 499_999)
    XCTAssertEqual(belowHard.statusLevel, .softWarning)

    let exactHard = makeConversation(tokens: 500_000)
    XCTAssertEqual(exactHard.statusLevel, .hardLimit)
    XCTAssertEqual(exactHard.statusDetail, "Acima do teto de 500 mil (compactação imediata)")
    XCTAssertEqual(exactHard.fractionOfHardLimit, 1.0, accuracy: 0.0001)
  }

  func testNilAndNegativeTokensAreHandledSafely() {
    let unknown = makeConversation(tokens: nil)
    XCTAssertEqual(unknown.statusLevel, .normal)
    XCTAssertEqual(unknown.formattedTokens, "—")
    XCTAssertEqual(unknown.fractionOfHardLimit, 0.0, accuracy: 0.0001)
    XCTAssertEqual(unknown.statusDetail, "Sem leitura de contexto")

    let negative = makeConversation(tokens: -50)
    XCTAssertEqual(negative.contextTokens, 0)
    XCTAssertEqual(negative.formattedTokens, "0")
  }

  func testFormatTokensScalesUnits() {
    XCTAssertEqual(ActiveConversation.formatTokens(850), "850")
    XCTAssertEqual(ActiveConversation.formatTokens(128_400), "128 mil")
    XCTAssertEqual(ActiveConversation.formatTokens(1_250_000), "1.2M")
  }

  func testClaudeTranscriptParserSumsLatestAssistantUsage() {
    let lines: [Substring] = [
      #"{"type":"user","message":{"content":"oi"}}"#,
      #"{"type":"assistant","message":{"usage":{"input_tokens":1200,"cache_read_input_tokens":10000,"cache_creation_input_tokens":800}}}"#,
      #"{"type":"assistant","message":{"usage":{"input_tokens":2500,"cache_read_input_tokens":40000,"cache_creation_input_tokens":1500}}}"#,
      #"{"type":"system","subtype":"turn_duration"}"#,
    ]

    let tokens = ClaudeTranscriptParser.contextTokens(in: lines)
    XCTAssertEqual(tokens, 44_000)
  }

  func testClaudeTranscriptParserSkipsMalformedOrOutOfRangeEntries() {
    let lines: [Substring] = [
      #"{"type":"assistant","message":{"usage":{"input_tokens":5000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
      #"{"type":"assistant","message":{"usage":{"input_tokens":-10}}}"#,
      #"linha quebrada com "assistant" e "usage""#,
    ]

    let tokens = ClaudeTranscriptParser.contextTokens(in: lines)
    XCTAssertEqual(tokens, 5_000)
  }

  private func makeConversation(tokens: Int?) -> ActiveConversation {
    ActiveConversation(
      id: "conv-1",
      name: "painel-dev",
      providerID: "claude",
      providerName: "Claude",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      contextTokens: tokens,
      modelContextWindow: nil
    )
  }
}
