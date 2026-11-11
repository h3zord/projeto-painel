import Foundation

/// Extrai janelas de cota da tela `/usage` do Claude Code sem realizar I/O.
nonisolated enum ClaudeUsageParser {
  private static let months = [
    "jan", "feb", "mar", "apr", "may", "jun",
    "jul", "aug", "sep", "oct", "nov", "dec",
  ]

  static func makeUsage(from screen: String, now: Date) throws(AppError) -> ProviderUsage {
    let parsedLimits = limits(in: screen, now: now)
    guard parsedLimits.contains(where: { $0.id == "claude-session" }) else {
      throw AppError.unexpectedOutputFormat(provider: .claude)
    }

    let plan: String =
      if screen.contains("Claude Max") {
        "Max"
      } else if screen.contains("Claude Pro") {
        "Pro"
      } else {
        "Assinatura"
      }

    return ProviderUsage(
      id: KnownProviderID.claude.rawValue,
      name: "Claude",
      plan: plan,
      icon: .asset("ClaudeIcon"),
      tint: .orange,
      sessionState: .active,
      limits: parsedLimits,
      lastUpdatedAt: now
    )
  }

  static func limits(in screen: String, now: Date) -> [UsageLimit] {
    let limitPattern =
      #/(?i)Current\s*(session|week\s*\(([^)]*)\))[^%\n]*?(\d{1,3})\s*%\s*used\s*(?:Resets\s*([^(\n]+?)\s*\(([A-Za-z0-9_/+\-]+)\))?/#
    var latest: [String: UsageLimit] = [:]

    for match in screen.matches(of: limitPattern) {
      guard let percentage = Int(match.output.3) else { continue }

      let scope = match.output.2
        .map { String($0) }?
        .lowercased()
        .replacingOccurrences(of: " only", with: "")
        .trimmingCharacters(in: .whitespaces)

      let resetsAt = resetDate(
        text: match.output.4.map(String.init),
        timeZone: match.output.5.map(String.init),
        now: now
      )

      switch scope {
      case nil:
        latest["claude-session"] = UsageLimit(
          id: "claude-session",
          name: "Sessão de 5 horas",
          detail: nil,
          window: .session,
          usedPercentage: percentage,
          resetsAt: resetsAt
        )
      case "all models"?:
        latest["claude-weekly"] = UsageLimit(
          id: "claude-weekly",
          name: "Todos os modelos",
          detail: "Semanal",
          window: .weekly,
          usedPercentage: percentage,
          resetsAt: resetsAt
        )
      default:
        break
      }
    }

    return ["claude-session", "claude-weekly"].compactMap { latest[$0] }
  }

  static func resetDate(text: String?, timeZone identifier: String?, now: Date) -> Date? {
    let resetPattern =
      #/(?i)^(?:([A-Za-z]{3})[a-z]*\.?\s*(\d{1,2})(?:,\s*\d{4})?\s*(?:at|,)?\s*)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)$/#
    guard
      let trimmed = text?.trimmingCharacters(in: .whitespaces),
      let match = trimmed.wholeMatch(of: resetPattern),
      var hour = Int(match.output.3),
      (1...12).contains(hour)
    else {
      return nil
    }

    let minute = match.output.4.flatMap { Int($0) } ?? 0
    guard (0...59).contains(minute) else { return nil }

    let isPM = match.output.5.lowercased() == "pm"
    if hour == 12 { hour = 0 }
    if isPM { hour += 12 }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = identifier.flatMap(TimeZone.init(identifier:)) ?? .current

    var components = calendar.dateComponents([.year, .month, .day], from: now)
    components.hour = hour
    components.minute = minute

    let monthName = match.output.1.map { $0.lowercased() }
    if let monthName, let monthIndex = months.firstIndex(of: monthName) {
      components.month = monthIndex + 1
      components.day = match.output.2.flatMap { Int($0) }
    }

    guard let date = calendar.date(from: components) else { return nil }

    if monthName == nil, date < now {
      return calendar.date(byAdding: .day, value: 1, to: date)
    }
    if monthName != nil, date < now.addingTimeInterval(-86_400) {
      return calendar.date(byAdding: .year, value: 1, to: date)
    }
    return date
  }
}
