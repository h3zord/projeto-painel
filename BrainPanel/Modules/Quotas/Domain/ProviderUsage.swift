import Foundation

nonisolated struct ProviderUsage: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let plan: String
  let icon: ProviderIcon
  let tint: ProviderTint
  let sessionState: SessionState
  let limits: [UsageLimit]
  let lastUpdatedAt: Date?

  init(
    id: String,
    name: String,
    plan: String,
    icon: ProviderIcon,
    tint: ProviderTint,
    sessionState: SessionState,
    limits: [UsageLimit],
    lastUpdatedAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.plan = plan
    self.icon = icon
    self.tint = tint
    self.sessionState = sessionState
    self.limits = limits
    self.lastUpdatedAt = lastUpdatedAt
  }

  var unavailableReason: String? {
    guard case .unavailable(let reason) = sessionState else { return nil }
    return reason
  }

  var staleReason: String? {
    guard case .stale(let reason, _) = sessionState else { return nil }
    return reason
  }

  var staleLastUpdatedAt: Date? {
    guard case .stale(_, let timestamp) = sessionState else { return nil }
    return timestamp
  }

  /// O cartão de resumo mostra a janela de 5 horas mais consumida entre os grupos.
  var sessionLimit: UsageLimit? {
    limits
      .filter { $0.window == .session }
      .max { $0.usedPercentage < $1.usedPercentage }
  }

  /// O cartão de resumo mostra a janela semanal mais consumida entre os grupos.
  var weeklyLimit: UsageLimit? {
    limits
      .filter { $0.window == .weekly }
      .max { $0.usedPercentage < $1.usedPercentage }
  }

  func recordingValidReading(at timestamp: Date) -> ProviderUsage {
    ProviderUsage(
      id: id,
      name: name,
      plan: plan,
      icon: icon,
      tint: tint,
      sessionState: .active,
      limits: limits,
      lastUpdatedAt: timestamp
    )
  }

  func stale(reason: String, fallbackDate: Date) -> ProviderUsage {
    let preservedTimestamp = staleLastUpdatedAt ?? lastUpdatedAt ?? fallbackDate
    return ProviderUsage(
      id: id,
      name: name,
      plan: plan,
      icon: icon,
      tint: tint,
      sessionState: .stale(reason: reason, lastUpdatedAt: preservedTimestamp),
      limits: limits,
      lastUpdatedAt: preservedTimestamp
    )
  }

  func unavailable(_ reason: String) -> ProviderUsage {
    ProviderUsage(
      id: id,
      name: name,
      plan: plan,
      icon: icon,
      tint: tint,
      sessionState: .unavailable(reason),
      limits: [],
      lastUpdatedAt: nil
    )
  }

  static func staleAgeSummary(since lastUpdatedAt: Date, now: Date) -> String {
    let elapsedSeconds = max(Int(now.timeIntervalSince(lastUpdatedAt)), 0)
    let totalMinutes = elapsedSeconds / 60
    let days = totalMinutes / 1_440
    let hours = (totalMinutes % 1_440) / 60
    let minutes = totalMinutes % 60

    if days > 0 {
      return "Última leitura válida há \(days)d \(hours)h"
    }
    if hours > 0 {
      return "Última leitura válida há \(hours)h \(minutes)m"
    }
    if minutes > 0 {
      return "Última leitura válida há \(minutes)m"
    }
    return "Última leitura válida há instantes"
  }
}

nonisolated enum ProviderIcon: Equatable, Sendable {
  case symbol(String)
  case asset(String)
}

nonisolated enum LimitWindow: Equatable, Sendable {
  case session
  case weekly
}

nonisolated struct UsageLimit: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let detail: String?
  let window: LimitWindow
  let usedPercentage: Int
  let resetsAt: Date?

  init(
    id: String,
    name: String,
    detail: String?,
    window: LimitWindow,
    usedPercentage: Int,
    resetsAt: Date?
  ) {
    self.id = id
    self.name = name
    self.detail = detail
    self.window = window
    self.usedPercentage = min(max(usedPercentage, 0), 100)
    self.resetsAt = resetsAt
  }

  var remainingPercentage: Int {
    100 - usedPercentage
  }

  var fraction: Double {
    Double(usedPercentage) / 100.0
  }
}

nonisolated enum SessionState: Equatable, Sendable {
  case active
  case stale(reason: String, lastUpdatedAt: Date)
  case unavailable(String)

  var hasUsableQuota: Bool {
    switch self {
    case .active, .stale:
      true
    case .unavailable:
      false
    }
  }

  var isStale: Bool {
    if case .stale = self {
      return true
    }
    return false
  }

  var label: String {
    switch self {
    case .active:
      "Sessão ativa"
    case .stale:
      "Leitura defasada"
    case .unavailable:
      "Indisponível"
    }
  }
}

nonisolated enum ProviderTint: Equatable, Sendable {
  case orange
  case blue
}

nonisolated extension ProviderUsage {
  static let placeholders: [ProviderUsage] = [
    ProviderUsage(
      id: KnownProviderID.claude.rawValue,
      name: "Claude",
      plan: "Pro / Max",
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      sessionState: .unavailable("Carregando"),
      limits: []
    ),
    ProviderUsage(
      id: KnownProviderID.gemini.rawValue,
      name: "Gemini",
      plan: "Google AI Pro",
      icon: .symbol("sparkle"),
      tint: .blue,
      sessionState: .unavailable("Carregando"),
      limits: []
    ),
  ]

  static func makePreviewData(now: Date) -> [ProviderUsage] {
    [
      ProviderUsage(
        id: KnownProviderID.claude.rawValue,
        name: "Claude",
        plan: "Pro / Max",
        icon: .asset("ClaudeIcon"),
        tint: .orange,
        sessionState: .active,
        limits: [
          UsageLimit(
            id: "claude-session",
            name: "Sessão de 5 horas",
            detail: nil,
            window: .session,
            usedPercentage: 52,
            resetsAt: now.addingTimeInterval(54 * 60)
          ),
          UsageLimit(
            id: "claude-weekly",
            name: "Todos os modelos",
            detail: "Semanal",
            window: .weekly,
            usedPercentage: 27,
            resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60)
          ),
        ],
        lastUpdatedAt: now
      ),
      ProviderUsage(
        id: KnownProviderID.gemini.rawValue,
        name: "Gemini",
        plan: "Google AI Pro",
        icon: .symbol("sparkle"),
        tint: .blue,
        sessionState: .active,
        limits: [
          UsageLimit(
            id: "gemini-4-carbon-weekly",
            name: "Gemini 4 Carbon",
            detail: "Semanal",
            window: .weekly,
            usedPercentage: 84,
            resetsAt: now.addingTimeInterval(46 * 60 * 60 + 47 * 60)
          ),
          UsageLimit(
            id: "gemini-2-5-pro-session",
            name: "Gemini 2.5 Pro",
            detail: "Sessão de 5 horas",
            window: .session,
            usedPercentage: 0,
            resetsAt: nil
          ),
          UsageLimit(
            id: "gemini-2-5-pro-weekly",
            name: "Gemini 2.5 Pro",
            detail: "Semanal",
            window: .weekly,
            usedPercentage: 1,
            resetsAt: now.addingTimeInterval(51 * 60 * 60 + 44 * 60)
          ),
          UsageLimit(
            id: "gemini-claude-and-gpt-models-session",
            name: "Claude e GPT",
            detail: "Sessão de 5 horas",
            window: .session,
            usedPercentage: 80,
            resetsAt: now.addingTimeInterval(4 * 60 * 60 + 24 * 60)
          ),
          UsageLimit(
            id: "gemini-claude-and-gpt-models-weekly",
            name: "Claude e GPT",
            detail: "Semanal",
            window: .weekly,
            usedPercentage: 41,
            resetsAt: now.addingTimeInterval(167 * 60 * 60 + 24 * 60)
          ),
        ],
        lastUpdatedAt: now
      ),
    ]
  }
}
