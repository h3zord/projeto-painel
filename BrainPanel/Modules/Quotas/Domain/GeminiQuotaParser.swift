import Foundation

/// Extrai grupos de cota da tela `/quota` do Antigravity (`agy`) sem realizar I/O.
nonisolated enum GeminiQuotaParser {
  private enum ModelGroup: String, CaseIterable {
    case argon
    case flash
    case claudeAndGPT = "claude-gpt"

    var displayName: String {
      switch self {
      case .argon:
        "Argon"
      case .flash:
        "Flash"
      case .claudeAndGPT:
        "Claude e GPT"
      }
    }

    static func matching(header: String) -> ModelGroup? {
      if header.contains("ARGON") {
        return .argon
      }
      if header == "GEMINI MODELS" || header.contains("FLASH") {
        return .flash
      }
      if header.contains("CLAUDE") || header.contains("GPT") {
        return .claudeAndGPT
      }
      return nil
    }
  }

  private struct Entry {
    let group: ModelGroup
    let window: LimitWindow
    let remaining: Double
    let resetsAt: Date?
  }

  static func makeUsage(from screen: String, now: Date) throws(AppError) -> ProviderUsage {
    let parsedEntries = entries(in: screen, now: now)
    guard !parsedEntries.isEmpty else {
      throw AppError.unexpectedOutputFormat(provider: .gemini)
    }

    var limits: [UsageLimit] = []
    for group in ModelGroup.allCases {
      let groupEntries =
        parsedEntries
        .filter { $0.group == group }
        .sorted { lhs, rhs in
          lhs.window == .session && rhs.window == .weekly
        }

      for entry in groupEntries {
        let kind = entry.window == .session ? "session" : "weekly"
        let detail = entry.window == .session ? "Sessão de 5 horas" : "Semanal"
        limits.append(
          UsageLimit(
            id: "gemini-\(group.rawValue)-\(kind)",
            name: group.displayName,
            detail: detail,
            window: entry.window,
            usedPercentage: Int((100 - entry.remaining).rounded()),
            resetsAt: entry.resetsAt
          )
        )
      }
    }

    let plan =
      if screen.contains("Google AI Ultra") {
        "Google AI Ultra"
      } else if screen.contains("Google AI Pro") {
        "Google AI Pro"
      } else {
        "Google"
      }

    return ProviderUsage(
      id: KnownProviderID.gemini.rawValue,
      name: "Gemini",
      plan: plan,
      icon: .symbol("sparkle"),
      tint: .blue,
      sessionState: .active,
      limits: limits
    )
  }

  private static func entries(in screen: String, now: Date) -> [Entry] {
    guard let start = screen.range(of: "Models & Quota", options: .backwards) else {
      return []
    }

    let lines = screen[start.upperBound...]
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }

    var collected: [Entry] = []
    var rawGroup: String?
    var label: String?
    var remaining: Double?
    var resetsAt: Date?

    func flush() {
      if let rawGroup,
        let group = ModelGroup.matching(header: rawGroup),
        let label,
        let remaining
      {
        let window: LimitWindow = isFiveHour(label) ? .session : .weekly
        collected.append(
          Entry(group: group, window: window, remaining: remaining, resetsAt: resetsAt)
        )
      }
      label = nil
      remaining = nil
      resetsAt = nil
    }

    for line in lines {
      if isGroupHeader(line) {
        flush()
        rawGroup = line
      } else if line.contains("Limit"), !line.contains("%") {
        flush()
        label = line
      } else if label != nil, remaining == nil, let value = percentage(in: line) {
        remaining = value
        resetsAt = resetDate(in: line, now: now)
      } else if remaining != nil, resetsAt == nil {
        resetsAt = resetDate(in: line, now: now)
      }
    }
    flush()

    return collected
  }

  private static func isFiveHour(_ label: String) -> Bool {
    label.localizedCaseInsensitiveContains("five hour")
      || label.localizedCaseInsensitiveContains("5-hour")
  }

  private static func isGroupHeader(_ line: String) -> Bool {
    line.count >= 4
      && line.uppercased() == line
      && line.contains(where: \.isLetter)
      && line.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " }
  }

  private static func percentage(in line: String) -> Double? {
    let percentPattern = #/(\d{1,3}(?:\.\d+)?)\s*%/#
    guard let match = line.firstMatch(of: percentPattern) else { return nil }
    return Double(match.output.1)
  }

  private static func resetDate(in line: String, now: Date) -> Date? {
    let durationPattern = #/(\d+)\s*(d|h|m|s)/#
    guard
      let marker = line.range(of: "refreshes in", options: .caseInsensitive)
        ?? line.range(of: "resets in", options: .caseInsensitive)
    else {
      return nil
    }

    let text = String(line[marker.upperBound...])
    let units: [String: TimeInterval] = ["d": 86_400, "h": 3_600, "m": 60, "s": 1]
    var seconds: TimeInterval = 0

    for match in text.matches(of: durationPattern) {
      guard
        let value = Double(match.output.1),
        let unit = units[String(match.output.2)]
      else {
        continue
      }
      seconds += value * unit
    }

    return seconds > 0 ? now.addingTimeInterval(seconds) : nil
  }
}
