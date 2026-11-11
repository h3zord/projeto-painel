import Foundation

nonisolated enum SessionBadgeIcon: Equatable, Sendable {
  case symbol(String)
  case asset(String)
}

nonisolated enum SessionAccentTint: Equatable, Sendable {
  case orange
  case blue
}

/// Representa uma conversa ativa detectada localmente e seu consumo atual da janela de contexto.
nonisolated struct ActiveConversation: Identifiable, Equatable, Sendable {
  static let softLimit = 300_000
  static let hardLimit = 500_000

  enum StatusLevel: Equatable, Sendable {
    case normal
    case softWarning
    case hardLimit
  }

  let id: String
  let name: String
  let providerID: String
  let providerName: String
  let icon: SessionBadgeIcon
  let tint: SessionAccentTint
  let contextTokens: Int?
  let modelContextWindow: Int?

  init(
    id: String,
    name: String,
    providerID: String,
    providerName: String,
    icon: SessionBadgeIcon,
    tint: SessionAccentTint,
    contextTokens: Int?,
    modelContextWindow: Int?
  ) {
    self.id = id
    self.name = name
    self.providerID = providerID
    self.providerName = providerName
    self.icon = icon
    self.tint = tint
    self.contextTokens = contextTokens.map { max($0, 0) }
    self.modelContextWindow = modelContextWindow.map { max($0, 0) }
  }

  var statusLevel: StatusLevel {
    guard let contextTokens else { return .normal }
    if contextTokens >= Self.hardLimit {
      return .hardLimit
    }
    if contextTokens >= Self.softLimit {
      return .softWarning
    }
    return .normal
  }

  var fractionOfHardLimit: Double {
    guard let contextTokens else { return 0 }
    return min(max(Double(contextTokens) / Double(Self.hardLimit), 0), 1)
  }

  var statusDetail: String {
    guard let contextTokens else { return "Sem leitura de contexto" }
    switch statusLevel {
    case .hardLimit:
      return "Acima do teto de 500 mil (compactação imediata)"
    case .softWarning:
      return "Acima de 300 mil (compactar na troca)"
    case .normal:
      let remainingToSoft = max(Self.softLimit - contextTokens, 0)
      return "\(Self.formatTokens(remainingToSoft)) até 300 mil"
    }
  }

  var formattedTokens: String {
    guard let contextTokens else { return "—" }
    return Self.formatTokens(contextTokens)
  }

  static func formatTokens(_ count: Int) -> String {
    let clamped = max(count, 0)
    if clamped >= 1_000_000 {
      let millions = Double(clamped) / 1_000_000
      return String(format: "%.1fM", millions)
    }
    if clamped >= 1_000 {
      let thousands = Int((Double(clamped) / 1_000).rounded())
      return "\(thousands) mil"
    }
    return "\(clamped)"
  }

  static let previewData: [ActiveConversation] = [
    ActiveConversation(
      id: "preview-claude-lead",
      name: "painel-lead",
      providerID: "claude",
      providerName: "Claude",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      contextTokens: 342_000,
      modelContextWindow: nil
    ),
    ActiveConversation(
      id: "preview-claude-dev",
      name: "painel-dev",
      providerID: "claude",
      providerName: "Claude",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      contextTokens: 128_400,
      modelContextWindow: nil
    ),
  ]
}

/// Parser puro de linhas JSONL de transcript do Claude Code, validado por schema `Decodable`.
nonisolated enum ClaudeTranscriptParser {
  private static let maxValidTokenCount = 50_000_000

  private struct TranscriptLineEnvelope: Decodable {
    let type: String
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

  static func contextTokens(in lines: [Substring]) -> Int? {
    let decoder = JSONDecoder()

    for line in lines.reversed() {
      guard
        line.contains("\"assistant\""),
        line.contains("\"usage\""),
        let data = String(line).data(using: .utf8),
        let envelope = try? decoder.decode(TranscriptLineEnvelope.self, from: data),
        envelope.type == "assistant",
        let usage = envelope.message?.usage
      else {
        continue
      }

      let input = clampTokenField(usage.inputTokens)
      let cacheRead = clampTokenField(usage.cacheReadInputTokens)
      let cacheCreation = clampTokenField(usage.cacheCreationInputTokens)
      guard input != nil || cacheRead != nil || cacheCreation != nil else {
        continue
      }

      return (input ?? 0) + (cacheRead ?? 0) + (cacheCreation ?? 0)
    }

    return nil
  }

  private static func clampTokenField(_ value: Int?) -> Int? {
    guard let value, value >= 0, value <= maxValidTokenCount else {
      return nil
    }
    return value
  }
}
