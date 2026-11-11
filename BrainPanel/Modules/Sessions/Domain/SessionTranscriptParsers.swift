import Foundation

/// Resultado puro da inspeção reversa de um transcript JSONL local.
nonisolated struct TranscriptSnapshot: Equatable, Sendable {
  let contextTokens: Int?
  let sessionName: String?
  let compaction: ActiveConversation.CompactionState

  static let empty = TranscriptSnapshot(
    contextTokens: nil,
    sessionName: nil,
    compaction: .notCompacted
  )
}

nonisolated enum SessionNameSanitizer {
  private static let maxNameLength = 80

  static func clean(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let normalized = raw.unicodeScalars.map { scalar -> Character in
      if CharacterSet.controlCharacters.contains(scalar) || scalar == "\n" || scalar == "\r" {
        return " "
      }
      return Character(scalar)
    }
    let collapsed = String(normalized)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    guard !collapsed.isEmpty else { return nil }
    return String(collapsed.prefix(maxNameLength))
  }
}

nonisolated private enum TranscriptTimestampParser {
  private static let maxTimestampLength = 64

  static func parse(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= maxTimestampLength else {
      return nil
    }
    if let withFraction = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(
      trimmed)
    {
      return withFraction
    }
    return try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(trimmed)
  }
}

/// Parser puro de linhas JSONL de transcript do Claude Code, validado por schema `Decodable`.
/// Não decodifica conteúdo de mensagens (`content`), lendo apenas metadados de uso, compactação e título.
nonisolated enum ClaudeTranscriptParser {
  private static let maxValidTokenCount = 50_000_000

  private struct TranscriptLineEnvelope: Decodable {
    let type: String?
    let subtype: String?
    let timestamp: String?
    let customTitle: String?
    let agentName: String?
    let message: AssistantMessage?
  }

  private struct AssistantMessage: Decodable {
    let usage: TokenUsage?
  }

  private struct TokenUsage: Decodable {
    let inputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    enum CodingKeys: String, CodingKey {
      case inputTokens = "input_tokens"
      case cacheReadInputTokens = "cache_read_input_tokens"
      case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
  }

  static func parse(lines: [Substring]) -> TranscriptSnapshot {
    let decoder = JSONDecoder()
    var resolvedTokens: Int?
    var resolvedCompaction: ActiveConversation.CompactionState = .notCompacted
    var hasResolvedContextState = false
    var resolvedName: String?

    for line in lines.reversed() {
      let mayContainMetadata =
        line.contains("\"usage\"")
        || line.contains("\"compact_boundary\"")
        || line.contains("\"customTitle\"")
        || line.contains("\"agentName\"")

      guard
        mayContainMetadata,
        let data = String(line).data(using: .utf8),
        let envelope = try? decoder.decode(TranscriptLineEnvelope.self, from: data)
      else {
        continue
      }

      if resolvedName == nil {
        resolvedName =
          SessionNameSanitizer.clean(envelope.customTitle)
          ?? SessionNameSanitizer.clean(envelope.agentName)
      }

      if !hasResolvedContextState {
        if envelope.type == "system", envelope.subtype == "compact_boundary" {
          resolvedCompaction = .compacted(at: TranscriptTimestampParser.parse(envelope.timestamp))
          hasResolvedContextState = true
        } else if envelope.type == "assistant",
          let usage = envelope.message?.usage,
          let total = validPositiveTokenSum(usage)
        {
          resolvedTokens = total
          hasResolvedContextState = true
        }
      }

      if hasResolvedContextState, resolvedName != nil {
        break
      }
    }

    return TranscriptSnapshot(
      contextTokens: resolvedTokens,
      sessionName: resolvedName,
      compaction: resolvedCompaction
    )
  }

  static func contextTokens(in lines: [Substring]) -> Int? {
    parse(lines: lines).contextTokens
  }

  private static func validPositiveTokenSum(_ usage: TokenUsage) -> Int? {
    guard
      isOptionalFieldValid(usage.inputTokens),
      isOptionalFieldValid(usage.cacheReadInputTokens),
      isOptionalFieldValid(usage.cacheCreationInputTokens)
    else {
      return nil
    }

    let total =
      (usage.inputTokens ?? 0)
      + (usage.cacheReadInputTokens ?? 0)
      + (usage.cacheCreationInputTokens ?? 0)
    return total > 0 ? total : nil
  }

  private static func isOptionalFieldValid(_ value: Int?) -> Bool {
    guard let value else { return true }
    return value >= 0 && value <= maxValidTokenCount
  }
}

/// Parser puro de linhas JSONL de transcript do Antigravity (`transcript.jsonl` / `transcript_full.jsonl`).
/// Soma `input_tokens + cache_read_tokens` do último `PLANNER_RESPONSE` ou marca compactação em `CHECKPOINT`.
nonisolated enum AntigravityTranscriptParser {
  private static let maxValidTokenCount = 50_000_000

  private struct StepEnvelope: Decodable {
    let type: String?
    let createdAt: String?
    let timestamp: String?
    let inputTokens: Int?
    let cacheReadTokens: Int?

    enum CodingKeys: String, CodingKey {
      case type
      case createdAt = "created_at"
      case timestamp
      case inputTokens = "input_tokens"
      case cacheReadTokens = "cache_read_tokens"
    }
  }

  static func parse(lines: [Substring]) -> TranscriptSnapshot {
    let decoder = JSONDecoder()

    for line in lines.reversed() {
      guard
        line.contains("\"PLANNER_RESPONSE\"") || line.contains("\"CHECKPOINT\""),
        let data = String(line).data(using: .utf8),
        let envelope = try? decoder.decode(StepEnvelope.self, from: data)
      else {
        continue
      }

      if envelope.type == "CHECKPOINT" {
        let timestamp = TranscriptTimestampParser.parse(envelope.createdAt ?? envelope.timestamp)
        return TranscriptSnapshot(
          contextTokens: nil,
          sessionName: nil,
          compaction: .compacted(at: timestamp)
        )
      }

      if envelope.type == "PLANNER_RESPONSE" {
        guard
          isOptionalFieldValid(envelope.inputTokens),
          isOptionalFieldValid(envelope.cacheReadTokens)
        else {
          continue
        }
        let total = (envelope.inputTokens ?? 0) + (envelope.cacheReadTokens ?? 0)
        if total > 0 {
          return TranscriptSnapshot(
            contextTokens: total,
            sessionName: nil,
            compaction: .notCompacted
          )
        }
      }
    }

    return .empty
  }

  private static func isOptionalFieldValid(_ value: Int?) -> Bool {
    guard let value else { return true }
    return value >= 0 && value <= maxValidTokenCount
  }
}
