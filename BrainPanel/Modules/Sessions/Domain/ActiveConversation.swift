import Foundation

nonisolated enum SessionBadgeIcon: Equatable, Sendable {
  case symbol(String)
  case asset(String)
}

nonisolated enum SessionAccentTint: Equatable, Sendable {
  case orange
  case blue
}

/// Representa uma conversa ativa detectada localmente e sua ocupação relativa da janela de contexto do Brain.
nonisolated struct ActiveConversation: Identifiable, Equatable, Sendable {
  static let defaultPresumedWindow = 1_000_000
  static let antigravityContextWindow = 1_048_576
  static let softWarningPercentage = 70
  static let hardLimitPercentage = 80

  enum StatusLevel: Equatable, Sendable {
    case normal
    case softWarning
    case hardLimit
  }

  enum CompactionState: Equatable, Sendable {
    case notCompacted
    case compacted(at: Date?)

    var isCompacted: Bool {
      switch self {
      case .notCompacted:
        false
      case .compacted:
        true
      }
    }

    var compactedAt: Date? {
      switch self {
      case .notCompacted:
        nil
      case .compacted(let date):
        date
      }
    }
  }

  let id: String
  let name: String
  let providerID: String
  let providerName: String
  let icon: SessionBadgeIcon
  let tint: SessionAccentTint
  let contextTokens: Int?
  let modelContextWindow: Int?
  let compaction: CompactionState

  init(
    id: String,
    name: String,
    providerID: String,
    providerName: String,
    icon: SessionBadgeIcon,
    tint: SessionAccentTint,
    contextTokens: Int?,
    modelContextWindow: Int?,
    compaction: CompactionState = .notCompacted
  ) {
    self.id = id
    self.name = name
    self.providerID = providerID
    self.providerName = providerName
    self.icon = icon
    self.tint = tint
    self.contextTokens = contextTokens.map { max($0, 0) }
    if let window = modelContextWindow, window > 0 {
      self.modelContextWindow = window
    } else {
      self.modelContextWindow = nil
    }
    self.compaction = compaction
  }

  var effectiveContextWindow: Int {
    modelContextWindow ?? Self.defaultPresumedWindow
  }

  var isWindowPresumed: Bool {
    modelContextWindow == nil
  }

  var isCompacted: Bool {
    compaction.isCompacted
  }

  var compactedAt: Date? {
    compaction.compactedAt
  }

  var statusLevel: StatusLevel {
    guard !isCompacted, let contextTokens else { return .normal }
    let window = Int64(effectiveContextWindow)
    let scaledTokens = Int64(contextTokens) * 100
    if scaledTokens >= window * Int64(Self.hardLimitPercentage) {
      return .hardLimit
    }
    if scaledTokens >= window * Int64(Self.softWarningPercentage) {
      return .softWarning
    }
    return .normal
  }

  var usageFraction: Double {
    guard !isCompacted, let contextTokens else { return 0 }
    return min(max(Double(contextTokens) / Double(effectiveContextWindow), 0), 1)
  }

  var usagePercentage: Int? {
    guard !isCompacted, let contextTokens else { return nil }
    let raw = (Int64(contextTokens) * 100) / Int64(effectiveContextWindow)
    return Int(min(max(raw, 0), 999))
  }

  var headlineMetric: String {
    if isCompacted {
      return "Compactada"
    }
    guard let pct = usagePercentage else { return "—" }
    return "\(pct)% · \(formattedTokens)"
  }

  var windowSummary: String {
    let formatted = Self.formatTokens(effectiveContextWindow)
    return isWindowPresumed ? "Janela \(formatted) (presumida)" : "Janela \(formatted)"
  }

  var statusDetail: String {
    statusDetail(now: nil)
  }

  func statusDetail(now: Date?) -> String {
    if isCompacted {
      if let compactedAt, let now {
        return
          "Compactou \(Self.relativeElapsedSummary(since: compactedAt, now: now)) · tamanho volta no próximo turno"
      }
      return "Compactou · tamanho volta no próximo turno"
    }

    guard let contextTokens else { return "Sem leitura de contexto" }
    switch statusLevel {
    case .hardLimit:
      return "Compactar no próximo ponto natural (≥ 80%)"
    case .softWarning:
      return "Perto de compactar (≥ 70%)"
    case .normal:
      let softThresholdTokens = Int(
        (Int64(effectiveContextWindow) * Int64(Self.softWarningPercentage) + 99) / 100
      )
      let remainingToSoft = max(softThresholdTokens - contextTokens, 0)
      return "\(Self.formatTokens(remainingToSoft)) até 70%"
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

  /// Ordena conversas por ocupação relativa decrescente, seguidas de sessões recém-compactadas e sessões sem leitura.
  static func prioritized(_ conversations: [ActiveConversation]) -> [ActiveConversation] {
    conversations.sorted(by: shouldPrecede)
  }

  private static func shouldPrecede(_ lhs: ActiveConversation, _ rhs: ActiveConversation) -> Bool {
    let lhsRank = priorityRank(of: lhs)
    let rhsRank = priorityRank(of: rhs)
    if lhsRank != rhsRank {
      return lhsRank < rhsRank
    }

    if lhsRank == 0, let lhsTokens = lhs.contextTokens, let rhsTokens = rhs.contextTokens {
      let lhsCross = Int64(lhsTokens) * Int64(rhs.effectiveContextWindow)
      let rhsCross = Int64(rhsTokens) * Int64(lhs.effectiveContextWindow)
      if lhsCross != rhsCross {
        return lhsCross > rhsCross
      }
      if lhsTokens != rhsTokens {
        return lhsTokens > rhsTokens
      }
    } else if lhsRank == 1 {
      let lhsDate = lhs.compactedAt ?? .distantPast
      let rhsDate = rhs.compactedAt ?? .distantPast
      if lhsDate != rhsDate {
        return lhsDate > rhsDate
      }
    }

    let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
    if nameOrder != .orderedSame {
      return nameOrder == .orderedAscending
    }
    return lhs.id < rhs.id
  }

  private static func priorityRank(of conversation: ActiveConversation) -> Int {
    if conversation.isCompacted {
      return 1
    }
    if conversation.contextTokens != nil {
      return 0
    }
    return 2
  }

  private static func relativeElapsedSummary(since timestamp: Date, now: Date) -> String {
    let elapsedSeconds = max(Int(now.timeIntervalSince(timestamp)), 0)
    let totalMinutes = elapsedSeconds / 60
    let days = totalMinutes / 1_440
    let hours = (totalMinutes % 1_440) / 60
    let minutes = totalMinutes % 60

    if days > 0 {
      return "há \(days)d \(hours)h"
    }
    if hours > 0 {
      return "há \(hours)h \(minutes)m"
    }
    if minutes > 0 {
      return "há \(minutes)m"
    }
    return "há instantes"
  }

  static let previewData: [ActiveConversation] = [
    ActiveConversation(
      id: "preview-claude-lead",
      name: "painel-lead",
      providerID: "claude",
      providerName: "Claude",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      contextTokens: 148_000,
      modelContextWindow: 200_000
    ),
    ActiveConversation(
      id: "preview-agy-dev",
      name: "painel-dev",
      providerID: "antigravity",
      providerName: "Antigravity",
      icon: .symbol("sparkle"),
      tint: .blue,
      contextTokens: 312_000,
      modelContextWindow: antigravityContextWindow
    ),
  ]
}
