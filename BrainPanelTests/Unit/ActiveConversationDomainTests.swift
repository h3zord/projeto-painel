import Foundation
import XCTest

@testable import BrainPanel

final class ActiveConversationDomainTests: XCTestCase {
  func testPercentageStatusBoundariesAcrossRegisteredPresumedAndAntigravityWindows() {
    // 1. Janela registrada de 200_000 (70% = 140_000; 80% = 160_000)
    let belowSoft200k = makeConversation(tokens: 139_999, window: 200_000)
    XCTAssertFalse(belowSoft200k.isWindowPresumed)
    XCTAssertEqual(belowSoft200k.effectiveContextWindow, 200_000)
    XCTAssertEqual(belowSoft200k.statusLevel, .normal)
    XCTAssertEqual(belowSoft200k.usagePercentage, 69)
    XCTAssertEqual(belowSoft200k.statusDetail, "1 até 70%")
    XCTAssertEqual(belowSoft200k.windowSummary, "Janela 200 mil")

    let exactSoft200k = makeConversation(tokens: 140_000, window: 200_000)
    XCTAssertEqual(exactSoft200k.statusLevel, .softWarning)
    XCTAssertEqual(exactSoft200k.usagePercentage, 70)
    XCTAssertEqual(exactSoft200k.headlineMetric, "70% · 140 mil")
    XCTAssertEqual(exactSoft200k.statusDetail, "Perto de compactar (≥ 70%)")

    let belowHard200k = makeConversation(tokens: 159_999, window: 200_000)
    XCTAssertEqual(belowHard200k.statusLevel, .softWarning)
    XCTAssertEqual(belowHard200k.usagePercentage, 79)

    let exactHard200k = makeConversation(tokens: 160_000, window: 200_000)
    XCTAssertEqual(exactHard200k.statusLevel, .hardLimit)
    XCTAssertEqual(exactHard200k.usagePercentage, 80)
    XCTAssertEqual(exactHard200k.statusDetail, "Compactar no próximo ponto natural (≥ 80%)")
    XCTAssertEqual(exactHard200k.usageFraction, 0.80, accuracy: 0.0001)

    // 2. Janela presumida padrão de 1_000_000 quando modelContextWindow é nil ou <= 0
    let belowSoftPresumed = makeConversation(tokens: 699_999, window: nil)
    XCTAssertTrue(belowSoftPresumed.isWindowPresumed)
    XCTAssertEqual(belowSoftPresumed.effectiveContextWindow, 1_000_000)
    XCTAssertEqual(belowSoftPresumed.statusLevel, .normal)
    XCTAssertEqual(belowSoftPresumed.usagePercentage, 69)
    XCTAssertEqual(belowSoftPresumed.windowSummary, "Janela 1.0M (presumida)")

    let zeroWindowFallback = makeConversation(tokens: 700_000, window: 0)
    XCTAssertTrue(zeroWindowFallback.isWindowPresumed)
    XCTAssertEqual(zeroWindowFallback.statusLevel, .softWarning)
    XCTAssertEqual(zeroWindowFallback.usagePercentage, 70)

    let belowHardPresumed = makeConversation(tokens: 799_999, window: nil)
    XCTAssertEqual(belowHardPresumed.statusLevel, .softWarning)

    let exactHardPresumed = makeConversation(tokens: 800_000, window: nil)
    XCTAssertEqual(exactHardPresumed.statusLevel, .hardLimit)
    XCTAssertEqual(exactHardPresumed.usagePercentage, 80)

    // 3. Janela Antigravity de 1_048_576 (70% = 734_003.2 -> 734_004; 80% = 838_860.8 -> 838_861)
    let agWindow = ActiveConversation.antigravityContextWindow
    XCTAssertEqual(makeConversation(tokens: 734_003, window: agWindow).statusLevel, .normal)
    XCTAssertEqual(makeConversation(tokens: 734_004, window: agWindow).statusLevel, .softWarning)
    XCTAssertEqual(makeConversation(tokens: 838_860, window: agWindow).statusLevel, .softWarning)
    XCTAssertEqual(makeConversation(tokens: 838_861, window: agWindow).statusLevel, .hardLimit)
    XCTAssertFalse(makeConversation(tokens: 838_861, window: agWindow).isWindowPresumed)
  }

  func testCompactedConversationStaysNormalWithoutFalseWarningAndFormatsElapsedTime() {
    let compactedAt = Date(timeIntervalSince1970: 1_762_818_300)
    let now = Date(timeIntervalSince1970: 1_762_819_200)  // +15 min

    let compacted = ActiveConversation(
      id: "conv-compacted",
      name: "painel-lead",
      providerID: "claude",
      providerName: "Claude",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      contextTokens: 850_000,
      modelContextWindow: 1_000_000,
      compaction: .compacted(at: compactedAt)
    )

    XCTAssertTrue(compacted.isCompacted)
    XCTAssertEqual(compacted.compactedAt, compactedAt)
    XCTAssertEqual(compacted.statusLevel, .normal)
    XCTAssertNil(compacted.usagePercentage)
    XCTAssertEqual(compacted.usageFraction, 0.0, accuracy: 0.0001)
    XCTAssertEqual(compacted.headlineMetric, "Compactada")
    XCTAssertEqual(
      compacted.statusDetail(now: now),
      "Compactou há 15m · tamanho volta no próximo turno"
    )
    XCTAssertEqual(
      compacted.statusDetail(now: nil),
      "Compactou · tamanho volta no próximo turno"
    )
  }

  func testNilAndNegativeTokensAreHandledSafely() {
    let unknown = makeConversation(tokens: nil, window: 200_000)
    XCTAssertEqual(unknown.statusLevel, .normal)
    XCTAssertEqual(unknown.formattedTokens, "—")
    XCTAssertEqual(unknown.headlineMetric, "—")
    XCTAssertEqual(unknown.usageFraction, 0.0, accuracy: 0.0001)
    XCTAssertEqual(unknown.statusDetail, "Sem leitura de contexto")

    let negative = makeConversation(tokens: -50, window: 200_000)
    XCTAssertEqual(negative.contextTokens, 0)
    XCTAssertEqual(negative.formattedTokens, "0")
    XCTAssertEqual(negative.usagePercentage, 0)
  }

  func testPrioritizedOrdersByRelativeOccupancyThenCompactedThenUnknown() {
    let highRelativeSmallWindow = makeConversation(
      id: "high-pct",
      name: "sessao-200k",
      tokens: 170_000,
      window: 200_000
    )  // 85%
    let lowerRelativeLargeWindow = makeConversation(
      id: "low-pct",
      name: "sessao-1m",
      tokens: 300_000,
      window: 1_000_000
    )  // 30%
    let compactedSession = ActiveConversation(
      id: "compacted",
      name: "sessao-compactada",
      providerID: "claude",
      providerName: "Claude",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      contextTokens: nil,
      modelContextWindow: 200_000,
      compaction: .compacted(at: Date(timeIntervalSince1970: 1_762_819_000))
    )
    let unknownSession = makeConversation(
      id: "unknown",
      name: "sessao-vazia",
      tokens: nil,
      window: 200_000
    )

    let ordered = ActiveConversation.prioritized([
      unknownSession,
      lowerRelativeLargeWindow,
      compactedSession,
      highRelativeSmallWindow,
    ])

    XCTAssertEqual(ordered.map(\.id), ["high-pct", "low-pct", "compacted", "unknown"])
  }

  func testFormatTokensScalesUnits() {
    XCTAssertEqual(ActiveConversation.formatTokens(850), "850")
    XCTAssertEqual(ActiveConversation.formatTokens(128_400), "128 mil")
    XCTAssertEqual(ActiveConversation.formatTokens(1_250_000), "1.2M")
  }

  func testClaudeTranscriptParserDetectsCompactionNewTurnAndNameFallbacks() {
    let compactedLines: [Substring] = [
      #"{"type":"agent-name","agentName":"agente-inicial"}"#,
      #"{"type":"custom-title","customTitle":"painel-lead"}"#,
      #"{"type":"assistant","message":{"usage":{"input_tokens":20000,"cache_read_input_tokens":400000,"cache_creation_input_tokens":0}}}"#,
      #"{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-11T06:06:02.125Z"}"#,
    ]

    let compactedSnapshot = ClaudeTranscriptParser.parse(lines: compactedLines)
    XCTAssertNil(compactedSnapshot.contextTokens)
    XCTAssertNil(ClaudeTranscriptParser.contextTokens(in: compactedLines))
    XCTAssertTrue(compactedSnapshot.compaction.isCompacted)
    XCTAssertNotNil(compactedSnapshot.compaction.compactedAt)
    XCTAssertEqual(compactedSnapshot.sessionName, "painel-lead")

    // Quando surge um novo turno medido após o compact_boundary, volta a reportar o contexto novo
    var resumedLines = compactedLines
    resumedLines.append(
      #"{"type":"assistant","message":{"usage":{"input_tokens":2500,"cache_read_input_tokens":60000,"cache_creation_input_tokens":1500}}}"#
    )
    resumedLines.append(#"{"type":"system","subtype":"turn_duration"}"#)

    let resumedSnapshot = ClaudeTranscriptParser.parse(lines: resumedLines)
    XCTAssertEqual(resumedSnapshot.contextTokens, 64_000)
    XCTAssertEqual(ClaudeTranscriptParser.contextTokens(in: resumedLines), 64_000)
    XCTAssertEqual(resumedSnapshot.compaction, .notCompacted)
    XCTAssertEqual(resumedSnapshot.sessionName, "painel-lead")
  }

  func testClaudeTranscriptParserSkipsMalformedZeroOrNegativeEntriesAndUsesAgentNameFallback() {
    let lines: [Substring] = [
      #"{"type":"agent-name","agentName":"  painel-dev  "}"#,
      #"{"type":"assistant","message":{"usage":{"input_tokens":5000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
      #"{"type":"assistant","message":{"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
      #"{"type":"assistant","message":{"usage":{"input_tokens":-10,"cache_read_input_tokens":200}}}"#,
      #"linha quebrada com "assistant" e "usage""#,
    ]

    let snapshot = ClaudeTranscriptParser.parse(lines: lines)
    XCTAssertEqual(snapshot.contextTokens, 5_000)
    XCTAssertEqual(snapshot.sessionName, "painel-dev")
    XCTAssertEqual(snapshot.compaction, .notCompacted)
  }

  func testAntigravityTranscriptParserExtractsPlannerResponseAndCheckpoint() {
    let checkpointedLines: [Substring] = [
      #"{"step_index":1,"type":"USER_INPUT","content":"oi"}"#,
      #"{"step_index":2,"type":"PLANNER_RESPONSE","input_tokens":15000,"cache_read_tokens":810000}"#,
      #"{"step_index":3,"type":"CHECKPOINT","created_at":"2026-11-11T03:06:02-03:00"}"#,
    ]

    let checkpointSnapshot = AntigravityTranscriptParser.parse(lines: checkpointedLines)
    XCTAssertNil(checkpointSnapshot.contextTokens)
    XCTAssertTrue(checkpointSnapshot.compaction.isCompacted)
    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let expectedCheckpointDate = utcCalendar.date(
      from: DateComponents(year: 2026, month: 11, day: 11, hour: 6, minute: 6, second: 2)
    )
    XCTAssertEqual(checkpointSnapshot.compaction.compactedAt, expectedCheckpointDate)

    var resumedLines = checkpointedLines
    resumedLines.append(
      #"{"step_index":4,"type":"PLANNER_RESPONSE","input_tokens":8000,"cache_read_tokens":92000}"#
    )

    let resumedSnapshot = AntigravityTranscriptParser.parse(lines: resumedLines)
    XCTAssertEqual(resumedSnapshot.contextTokens, 100_000)
    XCTAssertEqual(resumedSnapshot.compaction, .notCompacted)
  }

  private func makeConversation(
    id: String = "conv-1",
    name: String = "painel-dev",
    tokens: Int?,
    window: Int?
  ) -> ActiveConversation {
    ActiveConversation(
      id: id,
      name: name,
      providerID: "claude",
      providerName: "Claude",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      contextTokens: tokens,
      modelContextWindow: window
    )
  }
}
