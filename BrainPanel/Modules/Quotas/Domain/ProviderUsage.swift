import Foundation

nonisolated struct ProviderUsage: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let plan: String
  let icon: ProviderIcon
  let tint: ProviderTint
  let sessionState: SessionState
  let limits: [UsageLimit]

  var unavailableReason: String? {
    guard case .unavailable(let reason) = sessionState else { return nil }
    return reason
  }

  /// O cartão de resumo mostra a janela de 5 horas mais consumida entre os grupos.
  var sessionLimit: UsageLimit? {
    limits
      .filter { $0.window == .session }
      .max { $0.usedPercentage < $1.usedPercentage }
  }

  /// No Gemini exibe a janela semanal de Argon quando disponível; nos demais, a mais consumida.
  var weeklyLimit: UsageLimit? {
    if id == KnownProviderID.gemini.rawValue,
      let argonWeekly = limits.first(where: { $0.id == "gemini-argon-weekly" && $0.window == .weekly })
    {
      return argonWeekly
    }

    return
      limits
      .filter { $0.window == .weekly }
      .max { $0.usedPercentage < $1.usedPercentage }
  }

  func unavailable(_ reason: String) -> ProviderUsage {
    ProviderUsage(
      id: id,
      name: name,
      plan: plan,
      icon: icon,
      tint: tint,
      sessionState: .unavailable(reason),
      limits: []
    )
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
  case unavailable(String)

  var label: String {
    switch self {
    case .active:
      "Sessão ativa"
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
        ]
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
            id: "gemini-argon-weekly",
            name: "Argon",
            detail: "Semanal",
            window: .weekly,
            usedPercentage: 84,
            resetsAt: now.addingTimeInterval(46 * 60 * 60 + 47 * 60)
          ),
          UsageLimit(
            id: "gemini-flash-session",
            name: "Flash",
            detail: "Sessão de 5 horas",
            window: .session,
            usedPercentage: 0,
            resetsAt: nil
          ),
          UsageLimit(
            id: "gemini-flash-weekly",
            name: "Flash",
            detail: "Semanal",
            window: .weekly,
            usedPercentage: 1,
            resetsAt: now.addingTimeInterval(51 * 60 * 60 + 44 * 60)
          ),
          UsageLimit(
            id: "gemini-claude-gpt-session",
            name: "Claude e GPT",
            detail: "Sessão de 5 horas",
            window: .session,
            usedPercentage: 80,
            resetsAt: now.addingTimeInterval(4 * 60 * 60 + 24 * 60)
          ),
          UsageLimit(
            id: "gemini-claude-gpt-weekly",
            name: "Claude e GPT",
            detail: "Semanal",
            window: .weekly,
            usedPercentage: 41,
            resetsAt: now.addingTimeInterval(167 * 60 * 60 + 24 * 60)
          ),
        ]
      ),
    ]
  }
}
